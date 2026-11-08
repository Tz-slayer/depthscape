#include "depthmeshgeometry.h"

#include <QFileInfo>
#include <QImage>
#include <QtMath>
#include <QTimer>
#include <QFutureWatcher>
#include <QThreadPool>
#include <QtConcurrentRun>
#include <QVector3D>

#include <algorithm>
#include <array>
#include <bit>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <unordered_map>
#include <vector>

namespace {
constexpr int columns = 321;
constexpr int rows = 181;
constexpr int cellRefinement = 8;
constexpr int fineWidth = (columns - 1) * cellRefinement + 1;
constexpr int fineHeight = (rows - 1) * cellRefinement + 1;
constexpr float fieldOfView = 42.0f;
constexpr float distanceSpan = 1.3f;
constexpr float farPlane = 3.3f;
constexpr float nearDepthScale = 0.55f;
constexpr float farDepthScale = 1.45f;
constexpr float depthDetailThreshold = 0.08f;

struct Vertex { float x, y, z, u, v; };
struct VertexKey {
    std::uint32_t x, y, z, u, v;
    bool operator==(const VertexKey &) const = default;
};

struct VertexKeyHash {
    size_t operator()(const VertexKey &key) const noexcept
    {
        size_t hash = key.x;
        for (const auto value : {key.y, key.z, key.u, key.v})
            hash ^= size_t(value) + size_t(0x9e3779b9) + (hash << 6) + (hash >> 2);
        return hash;
    }
};

VertexKey keyFor(const Vertex &vertex)
{
    return {std::bit_cast<std::uint32_t>(vertex.x), std::bit_cast<std::uint32_t>(vertex.y),
        std::bit_cast<std::uint32_t>(vertex.z), std::bit_cast<std::uint32_t>(vertex.u),
        std::bit_cast<std::uint32_t>(vertex.v)};
}

QString localPath(const QUrl &url)
{
    const QString path = url.isLocalFile() ? url.toLocalFile() : url.toString();
    return QFileInfo(path).isAbsolute() ? path : QString();
}

QRect centeredCrop(const QSize &size, float aspect)
{
    QRect crop(QPoint(0, 0), size);
    const float sourceAspect = float(size.width()) / std::max(1, size.height());
    if (sourceAspect > aspect) {
        crop.setWidth(std::max(1, qRound(size.height() * aspect)));
        crop.moveLeft((size.width() - crop.width()) / 2);
    } else {
        crop.setHeight(std::max(1, qRound(size.width() / aspect)));
        crop.moveTop((size.height() - crop.height()) / 2);
    }
    return crop;
}

QImage cropResize(const QImage &image, float aspect)
{
    return image.copy(centeredCrop(image.size(), aspect))
        .scaled(fineWidth, fineHeight, Qt::IgnoreAspectRatio, Qt::SmoothTransformation);
}

// Blur a scalar field without changing its extent, reflecting edge samples.
std::vector<float> blurField(const std::vector<float> &input, float sigma)
{
    const int radius = int(std::ceil(sigma * 3.0f));
    std::vector<float> weights(size_t(radius * 2 + 1));
    float weightSum = 0;
    for (int d = -radius; d <= radius; ++d) {
        const float w = std::exp(-float(d * d) / (2 * sigma * sigma));
        weights[size_t(d + radius)] = w;
        weightSum += w;
    }
    for (auto &w : weights) w /= weightSum;
    std::vector<float> horizontal(input.size()), output(input.size());
    const auto reflect = [](int index, int length) {
        if (index < 0) return -index;
        if (index >= length) return 2 * length - index - 2;
        return index;
    };
    for (int y = 0; y < fineHeight; ++y) {
        for (int x = 0; x < fineWidth; ++x) {
            float value = 0;
            for (int d = -radius; d <= radius; ++d)
                value += input[size_t(y) * fineWidth + reflect(x + d, fineWidth)] * weights[size_t(d + radius)];
            horizontal[size_t(y) * fineWidth + x] = value;
        }
    }
    for (int y = 0; y < fineHeight; ++y) {
        for (int x = 0; x < fineWidth; ++x) {
            float value = 0;
            for (int d = -radius; d <= radius; ++d)
                value += horizontal[size_t(reflect(y + d, fineHeight)) * fineWidth + x] * weights[size_t(d + radius)];
            output[size_t(y) * fineWidth + x] = value;
        }
    }
    return output;
}

// Dilate the thresholded matte with an elliptical footprint, then soften it.
std::vector<float> expandedCoverage(const QImage &matte)
{
    constexpr int radius = 7;
    std::vector<float> expanded(size_t(fineWidth) * fineHeight, 0.0f);
    for (int y = 0; y < fineHeight; ++y) {
        float *output = expanded.data() + size_t(y) * fineWidth;
        for (int dy = -radius; dy <= radius; ++dy) {
            const int sourceY = y + dy;
            if (sourceY < 0 || sourceY >= fineHeight) continue;
            const int rx = int(std::lround(radius * std::sqrt(1.0 - double(dy * dy) / (radius * radius))));
            const auto *row = matte.constScanLine(sourceY);
            int count = 0;
            for (int x = 0; x < fineWidth; ++x) {
                if (x == 0) for (int j = 0; j <= rx; ++j) count += row[j] > 24;
                else {
                    if (x + rx < fineWidth) count += row[x + rx] > 24;
                    if (x - rx - 1 >= 0) count -= row[x - rx - 1] > 24;
                }
                if (count > 0) output[x] = 1.0f;
            }
        }
    }
    return blurField(expanded, 3.0f);
}

// Extend subject depth by the nearest matte sample. For each row, find its
// nearest subject pixel; then solve the vertical squared-distance transform
// with a lower envelope of parabolas. This gives exact Euclidean nearest labels.
std::vector<float> extendedSubjectDepth(const std::vector<float> &source, const QImage &matte)
{
    constexpr int none = -1;
    std::vector<std::int16_t> nearestX(source.size(), none);
    bool any = false;
    for (int y = 0; y < fineHeight; ++y) {
        const auto *row = matte.constScanLine(y);
        auto *labels = nearestX.data() + size_t(y) * fineWidth;
        int last = none;
        for (int x = 0; x < fineWidth; ++x) {
            if (row[x] > 16) { last = x; any = true; }
            labels[x] = static_cast<std::int16_t>(last);
        }
        last = none;
        for (int x = fineWidth - 1; x >= 0; --x) {
            if (row[x] > 16) last = x;
            if (last >= 0 && (labels[x] < 0 || last - x < x - labels[x]))
                labels[x] = static_cast<std::int16_t>(last);
        }
    }
    if (!any) return {};

    std::vector<float> extended(source.size());
    std::vector<int> candidates(size_t(fineHeight), 0);
    std::vector<double> boundaries(size_t(fineHeight + 1), 0);
    for (int x = 0; x < fineWidth; ++x) {
        int n = 0;
        const auto cost = [&](int y) {
            const int sx = nearestX[size_t(y) * fineWidth + x];
            return (x - sx) * (x - sx);
        };
        for (int y = 0; y < fineHeight; ++y) {
            if (nearestX[size_t(y) * fineWidth + x] < 0) continue;
            double intersection = -std::numeric_limits<double>::infinity();
            while (n > 0) {
                const int previous = candidates[size_t(n - 1)];
                intersection = double(cost(y) + y * y - cost(previous) - previous * previous)
                    / (2.0 * (y - previous));
                if (intersection > boundaries[size_t(n - 1)]) break;
                --n;
            }
            candidates[size_t(n)] = y;
            boundaries[size_t(n)] = n == 0 ? -std::numeric_limits<double>::infinity() : intersection;
            ++n;
        }
        boundaries[size_t(n)] = std::numeric_limits<double>::infinity();
        int k = 0;
        for (int y = 0; y < fineHeight; ++y) {
            while (k + 1 < n && boundaries[size_t(k + 1)] < y) ++k;
            const int sy = candidates[size_t(k)];
            const int sx = nearestX[size_t(sy) * fineWidth + x];
            extended[size_t(y) * fineWidth + x] = source[size_t(sy) * fineWidth + sx];
        }
    }
    return blurField(extended, 3.0f);
}
}

DepthMeshGeometry::DepthMeshGeometry(QQuick3DObject *parent)
    : QQuick3DGeometry(parent)
{
    setStride(sizeof(Vertex));
    setPrimitiveType(PrimitiveType::Triangles);
    addAttribute(Attribute::IndexSemantic, 0, Attribute::U32Type);
    addAttribute(Attribute::PositionSemantic, offsetof(Vertex, x), Attribute::F32Type);
    addAttribute(Attribute::TexCoord0Semantic, offsetof(Vertex, u), Attribute::F32Type);
}

void DepthMeshGeometry::setDepthPath(const QUrl &value)
{
    if (m_depthPath == value) return;
    m_depthPath = value;
    emit depthPathChanged();
    scheduleRebuild();
}

void DepthMeshGeometry::setMattePath(const QUrl &value)
{
    if (m_mattePath == value) return;
    m_mattePath = value;
    emit mattePathChanged();
    scheduleRebuild();
}

void DepthMeshGeometry::setOutputAspect(float value)
{
    const float bounded = std::clamp(value, 0.5f, 4.0f);
    if (qAbs(m_outputAspect - bounded) < 0.00001f) return;
    m_outputAspect = bounded;
    emit outputAspectChanged();
    scheduleRebuild();
}

void DepthMeshGeometry::setSourceAspect(float value)
{
    const float bounded = std::clamp(value, 0.01f, 100.0f);
    if (qAbs(m_sourceAspect - bounded) < 0.00001f) return;
    m_sourceAspect = bounded;
    emit sourceAspectChanged();
    scheduleRebuild();
}

void DepthMeshGeometry::setImageZoom(float value)
{
    const float bounded = std::clamp(value, 1.0f, 1.5f);
    if (qAbs(m_imageZoom - bounded) < 0.00001f) return;
    m_imageZoom = bounded;
    emit imageZoomChanged();
    scheduleRebuild();
}

void DepthMeshGeometry::setForeground(bool value)
{
    if (m_foreground == value) return;
    m_foreground = value;
    emit foregroundChanged();
    scheduleRebuild();
}

void DepthMeshGeometry::setValid(bool value)
{
    if (m_valid == value) return;
    m_valid = value;
    emit validChanged();
}

void DepthMeshGeometry::scheduleRebuild()
{
    // QML assigns several geometry properties in one turn. Build once after
    // those bindings have settled instead of rebuilding for each assignment.
    ++m_revision;
    setValid(false);
    if (m_rebuildScheduled) return;
    m_rebuildScheduled = true;
    QTimer::singleShot(0, this, [this] {
        m_rebuildScheduled = false;
        rebuild();
    });
}

struct MeshBuildInput {
    QUrl depthPath;
    QUrl mattePath;
    float outputAspect;
    float sourceAspect;
    float imageZoom;
    bool foreground;
};

struct MeshBuildResult {
    QByteArray vertices;
    QByteArray indices;
    QVector3D minimum;
    QVector3D maximum;
    float focusDistance = 0;
    float backgroundDistance = 0;
    bool valid = false;
};

static QThreadPool *meshThreadPool()
{
    static QThreadPool pool;
    static const bool configured = [] { pool.setMaxThreadCount(1); return true; }();
    Q_UNUSED(configured);
    return &pool;
}

static MeshBuildResult generateMesh(const MeshBuildInput &input)
{
    const QString depthFile = localPath(input.depthPath);
    const QString matteFile = localPath(input.mattePath);
    if (depthFile.isEmpty() || matteFile.isEmpty()) return {};

    QImage rawDepth(depthFile);
    QImage rawMatte(matteFile);
    if (rawDepth.isNull() || rawMatte.isNull()) return {};
    rawDepth = rawDepth.convertToFormat(QImage::Format_Grayscale16);
    rawMatte = rawMatte.convertToFormat(QImage::Format_Grayscale8);
    if (rawDepth.size() != rawMatte.size()) return {};
    const QImage depthImage = cropResize(rawDepth, input.outputAspect);
    const QImage matteImage = cropResize(rawMatte, input.outputAspect);

    const auto sourceDepthAt = [&depthImage](int x, int y) {
        const auto *row = reinterpret_cast<const quint16 *>(depthImage.constScanLine(y));
        return row[x] / 65535.0f;
    };
    const auto alphaAt = [&matteImage](int x, int y) {
        return matteImage.constScanLine(y)[x];
    };

    const float pivotDepth = sourceDepthAt(fineWidth / 2, fineHeight / 2);
    std::array<size_t, 256> histogram{};
    size_t count = 0;
    for (int y = 0; y < fineHeight; y += cellRefinement) {
        for (int x = 0; x < fineWidth; x += cellRefinement) {
            if (alphaAt(x, y) > 12) continue;
            ++histogram[static_cast<int>(sourceDepthAt(x, y) * 255.0f)];
            ++count;
        }
    }
    float backgroundDepth = std::max(0.05f, pivotDepth * 0.5f);
    size_t cumulative = 0;
    for (int bin = 0; bin < int(histogram.size()) && count; ++bin) {
        cumulative += histogram[size_t(bin)];
        if (cumulative >= count / 5) {
            backgroundDepth = (bin + 0.5f) / 256.0f;
            break;
        }
    }

    std::vector<float> field(size_t(fineWidth) * fineHeight);
    for (int y = 0; y < fineHeight; ++y)
        for (int x = 0; x < fineWidth; ++x)
            field[size_t(y) * fineWidth + x] = sourceDepthAt(x, y);
    if (input.foreground) {
        field = extendedSubjectDepth(field, matteImage);
        if (field.empty()) return {};
    } else {
        const std::vector<float> coverage = expandedCoverage(matteImage);
        for (size_t i = 0; i < field.size(); ++i)
            field[i] = field[i] * (1.0f - coverage[i]) + backgroundDepth * coverage[i];
    }
    const auto depthAt = [&field](int x, int y) {
        return field[size_t(y) * fineWidth + x];
    };

    const float pivotDistance = farPlane - pivotDepth * distanceSpan;
    const auto distanceAt = [&input, pivotDepth, pivotDistance](float depth) {
        if (input.foreground || depth >= pivotDepth)
            return pivotDistance - (depth - pivotDepth) * distanceSpan * nearDepthScale;
        return pivotDistance + (pivotDepth - depth) * distanceSpan * farDepthScale;
    };

    const float tangent = std::tan(qDegreesToRadians(fieldOfView / 2.0f));
    const float cropU = std::min(1.0f, input.outputAspect / input.sourceAspect);
    const float cropV = std::min(1.0f, input.sourceAspect / input.outputAspect);
    const float offsetU = (1.0f - cropU) / 2.0f;
    const float offsetV = (1.0f - cropV) / 2.0f;
    const auto vertexAt = [&](int x, int y, float depth) {
        const float u = float(x) / (fineWidth - 1);
        const float v = float(y) / (fineHeight - 1);
        const float distance = distanceAt(depth);
        return Vertex{
            (u * 2.0f - 1.0f) * input.imageZoom * distance * tangent * input.outputAspect,
            (1.0f - v * 2.0f) * input.imageZoom * distance * tangent,
            -distance,
            offsetU + u * cropU,
            1.0f - offsetV - v * cropV
        };
    };

    std::vector<Vertex> vertices;
    std::vector<std::uint32_t> indices;
    const size_t cellCount = size_t(columns - 1) * size_t(rows - 1);
    vertices.reserve(cellCount * 2);
    indices.reserve(cellCount * 6);
    std::unordered_map<VertexKey, std::uint32_t, VertexKeyHash> vertexIndices;
    vertexIndices.reserve(cellCount * 4);
    QVector3D minimum(std::numeric_limits<float>::max(), std::numeric_limits<float>::max(), std::numeric_limits<float>::max());
    QVector3D maximum(std::numeric_limits<float>::lowest(), std::numeric_limits<float>::lowest(), std::numeric_limits<float>::lowest());
    float farthest = 0.0f;
    const auto addVertex = [&](const Vertex &vertex) {
        const auto [it, inserted] = vertexIndices.try_emplace(
            keyFor(vertex), static_cast<std::uint32_t>(vertices.size()));
        if (inserted)
            vertices.push_back(vertex);
        minimum.setX(std::min(minimum.x(), vertex.x));
        minimum.setY(std::min(minimum.y(), vertex.y));
        minimum.setZ(std::min(minimum.z(), vertex.z));
        maximum.setX(std::max(maximum.x(), vertex.x));
        maximum.setY(std::max(maximum.y(), vertex.y));
        maximum.setZ(std::max(maximum.z(), vertex.z));
        farthest = std::max(farthest, -vertex.z);
        return it->second;
    };
    const auto triangle = [&](const Vertex &a, const Vertex &b, const Vertex &c) {
        indices.push_back(addVertex(a));
        indices.push_back(addVertex(b));
        indices.push_back(addVertex(c));
    };

    constexpr int cellColumns = columns - 1;
    constexpr int cellRows = rows - 1;
    // Classify first so each fine patch can match an adjacent coarse edge.
    std::vector<std::uint8_t> cellFlags(size_t(cellColumns) * cellRows, 0);
    for (int y = 0; y < cellRows; ++y) {
        for (int x = 0; x + 1 < columns; ++x) {
            const int x0 = x * cellRefinement;
            const int y0 = y * cellRefinement;
            float low = 1.0f, high = 0.0f;
            int maxAlpha = 0;
            for (int sy = 0; sy <= cellRefinement; ++sy) {
                for (int sx = 0; sx <= cellRefinement; ++sx) {
                    const float d = depthAt(x0 + sx, y0 + sy);
                    low = std::min(low, d);
                    high = std::max(high, d);
                    maxAlpha = std::max(maxAlpha, int(alphaAt(x0 + sx, y0 + sy)));
                }
            }
            if (input.foreground && maxAlpha == 0) continue;
            cellFlags[size_t(y) * cellColumns + x] = high - low > depthDetailThreshold ? 2 : 1;
        }
    }
    const auto coarseNeighbor = [&cellFlags](int x, int y) {
        return x >= 0 && x < cellColumns && y >= 0 && y < cellRows
            && cellFlags[size_t(y) * cellColumns + x] == 1;
    };
    const auto mixVertex = [](const Vertex &a, const Vertex &b, float t) {
        return Vertex{a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t,
            a.z + (b.z - a.z) * t, a.u + (b.u - a.u) * t, a.v + (b.v - a.v) * t};
    };
    for (int y = 0; y < cellRows; ++y) {
        for (int x = 0; x < cellColumns; ++x) {
            const int x0 = x * cellRefinement, y0 = y * cellRefinement;
            const auto flag = cellFlags[size_t(y) * cellColumns + x];
            if (!flag) continue;
            const Vertex tl = vertexAt(x0, y0, depthAt(x0, y0));
            const Vertex tr = vertexAt(x0 + cellRefinement, y0, depthAt(x0 + cellRefinement, y0));
            const Vertex bl = vertexAt(x0, y0 + cellRefinement, depthAt(x0, y0 + cellRefinement));
            const Vertex br = vertexAt(x0 + cellRefinement, y0 + cellRefinement, depthAt(x0 + cellRefinement, y0 + cellRefinement));
            if (flag == 1) {
                triangle(tl, bl, tr);
                triangle(tr, bl, br);
                continue;
            }
            const auto patchVertex = [&](int sx, int sy) {
                const float tx = float(sx) / cellRefinement, ty = float(sy) / cellRefinement;
                if (sy == 0 && coarseNeighbor(x, y - 1)) return mixVertex(tl, tr, tx);
                if (sy == cellRefinement && coarseNeighbor(x, y + 1)) return mixVertex(bl, br, tx);
                if (sx == 0 && coarseNeighbor(x - 1, y)) return mixVertex(tl, bl, ty);
                if (sx == cellRefinement && coarseNeighbor(x + 1, y)) return mixVertex(tr, br, ty);
                return vertexAt(x0 + sx, y0 + sy, depthAt(x0 + sx, y0 + sy));
            };
            for (int sy = 0; sy < cellRefinement; ++sy) {
                for (int sx = 0; sx < cellRefinement; ++sx) {
                    const Vertex a = patchVertex(sx, sy), b = patchVertex(sx + 1, sy);
                    const Vertex c = patchVertex(sx, sy + 1), d = patchVertex(sx + 1, sy + 1);
                    triangle(a, c, b);
                    triangle(b, c, d);
                }
            }
        }
    }
    if (indices.empty()) return {};
    return {
        QByteArray(reinterpret_cast<const char *>(vertices.data()),
            qsizetype(vertices.size() * sizeof(Vertex))),
        QByteArray(reinterpret_cast<const char *>(indices.data()),
            qsizetype(indices.size() * sizeof(std::uint32_t))),
        minimum, maximum, pivotDistance, farthest + 0.25f, true
    };
}

void DepthMeshGeometry::rebuild()
{
    if (m_buildRunning) return;
    const MeshBuildInput input{m_depthPath, m_mattePath, m_outputAspect,
        m_sourceAspect, m_imageZoom, m_foreground};
    const quint64 revision = m_revision;
    m_buildRunning = true;
    auto *watcher = new QFutureWatcher<MeshBuildResult>(this);
    connect(watcher, &QFutureWatcher<MeshBuildResult>::finished, this, [this, watcher, revision] {
        const MeshBuildResult result = watcher->result();
        watcher->deleteLater();
        m_buildRunning = false;
        if (revision != m_revision) {
            rebuild();
            return;
        }
        setVertexData(result.vertices);
        setIndexData(result.indices);
        if (!result.valid) {
            setValid(false);
            update();
            return;
        }
        setBounds(result.minimum, result.maximum);
        if (qAbs(m_focusDistance - result.focusDistance) > 0.00001f) {
            m_focusDistance = result.focusDistance;
            emit focusDistanceChanged();
        }
        if (qAbs(m_backgroundDistance - result.backgroundDistance) > 0.00001f) {
            m_backgroundDistance = result.backgroundDistance;
            emit backgroundDistanceChanged();
        }
        if (revision != m_revision) {
            rebuild();
            return;
        }
        setValid(true);
        update();
    });
    watcher->setFuture(QtConcurrent::run(meshThreadPool(), [input] { return generateMesh(input); }));
}
