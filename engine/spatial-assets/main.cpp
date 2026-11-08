#include <opencv2/core.hpp>
#include <opencv2/imgcodecs.hpp>
#include <opencv2/imgproc.hpp>
#if __has_include(<opencv2/geometry/2d.hpp>)
#include <opencv2/geometry/2d.hpp>
#endif
#include <algorithm>
#include <cmath>
#include <iostream>
#include <string>
#include <vector>

namespace {
cv::Mat ellipse(int n) { return cv::getStructuringElement(cv::MORPH_ELLIPSE, {n, n}); }

// Select a compact connected region and avoid candidates cropped by the top or
// sides. A subject may extend beyond the bottom edge of a photograph.
cv::Mat component(const cv::Mat &input, double minArea, double maxArea, bool bottomAllowed = false, bool edgeAllowed = false) {
    cv::Mat labels, stats, centers;
    const int count = cv::connectedComponentsWithStats(input, labels, stats, centers, 8);
    int best = 0;
    for (int i = 1; i < count; ++i) {
        int area = stats.at<int>(i, cv::CC_STAT_AREA);
        int x = stats.at<int>(i, cv::CC_STAT_LEFT), y = stats.at<int>(i, cv::CC_STAT_TOP);
        int right = x + stats.at<int>(i, cv::CC_STAT_WIDTH), bottom = y + stats.at<int>(i, cv::CC_STAT_HEIGHT);
        if (area < input.total() * minArea || area > input.total() * maxArea || (!edgeAllowed && (x < 2 || y < 2 || right > input.cols - 2)) || (!bottomAllowed && bottom > input.rows - 2)) continue;
        if (!best || area > stats.at<int>(best, cv::CC_STAT_AREA)) best = i;
    }
    return best ? (labels == best) : cv::Mat();
}

void restoreHoles(cv::Mat &mask, const cv::Mat &depth) {
    if (mask.empty()) return;
    int diameter = std::clamp(int(std::lround(std::min(mask.cols, mask.rows) * 0.025)), 9, 41) | 1;
    cv::Mat closed, flooded, holes, newlyClosed, originalOutside, labels, stats, centers;
    cv::morphologyEx(mask, closed, cv::MORPH_CLOSE, ellipse(diameter));
    flooded = closed.clone();
    cv::floodFill(flooded, {0, 0}, 255);
    cv::bitwise_not(flooded, holes);
    // Include holes closed by the morphology operation itself. Looking only
    // at residual holes would lose the very pixels the closing step repaired.
    cv::bitwise_not(mask, originalOutside);
    cv::bitwise_and(closed, originalOutside, newlyClosed);
    cv::bitwise_or(holes, newlyClosed, holes);
    int count = cv::connectedComponentsWithStats(holes, labels, stats, centers, 8);
    for (int i = 1; i < count; ++i) {
        int area = stats.at<int>(i, cv::CC_STAT_AREA);
        if (area > mask.total() * 0.025) continue;
        cv::Mat hole = labels == i, ring, supported;
        cv::dilate(hole, ring, ellipse(7));
        cv::bitwise_and(ring, mask, ring);
        if (!cv::countNonZero(ring)) continue;
        supported = depth >= std::max(0.0, cv::mean(depth, ring)[0] - 6553.5);
        cv::bitwise_and(supported, hole, supported);
        if (cv::countNonZero(supported) >= area * 0.8) mask.setTo(255, hole);
    }
}

cv::Mat segmentDepth(const cv::Mat &photo, const cv::Mat &depth, bool edgeSubject) {
    const int w = photo.cols, h = photo.rows;
    cv::Mat candidate, seed, labels(photo.size(), CV_8U, cv::Scalar(cv::GC_BGD));
    if (!edgeSubject) {
        candidate = component(depth > 0.30 * 65535, 0.015, 0.55);
        if (candidate.empty()) return {};
        cv::Mat inside, around;
        cv::erode(candidate, inside, ellipse(21));
        cv::dilate(candidate, around, ellipse(21));
        labels.setTo(cv::GC_PR_BGD, around);
        labels.setTo(cv::GC_PR_FGD, candidate);
        labels.setTo(cv::GC_FGD, inside);
        seed = candidate;
    } else {
        cv::Mat high = depth > 0.58 * 65535;
        high.rowRange(int(h * 0.78), h).setTo(0);
        high.colRange(0, int(w * 0.12)).setTo(0);
        high.colRange(int(w * 0.88), w).setTo(0);
        seed = component(high, 0.004, 0.22);
        if (seed.empty()) return {};
        cv::Mat expanded = depth > 0.50 * 65535;
        expanded.rowRange(int(h * 0.78), h).setTo(0);
        expanded.colRange(0, int(w * 0.12)).setTo(0);
        expanded.colRange(int(w * 0.88), w).setTo(0);
        expanded = component(expanded, 0.004, 0.45, true);
        cv::Rect box = cv::boundingRect(seed);
        if (!expanded.empty()) {
            cv::Mat overlap; cv::bitwise_and(expanded, seed, overlap);
            cv::Rect candidateBox = cv::boundingRect(expanded);
            if (cv::countNonZero(overlap) >= cv::countNonZero(seed) * 0.8 && candidateBox.width < w * 0.75) box = candidateBox;
            else expanded.release();
        }
        int margin = std::max(int(w * 0.025), int(box.width * 0.12));
        int left = std::max(2, box.x - margin), right = std::min(w - 2, box.x + box.width + margin), top = std::max(2, box.y - box.height / 6);
        if (right - left < w * 0.08 || top > h * 0.62) return {};
        labels(cv::Rect(left, top, right - left, h - top)).setTo(cv::GC_PR_BGD);
        cv::Mat likely = depth > 0.48 * 65535;
        if (!expanded.empty()) cv::bitwise_and(likely, expanded, likely);
        likely.colRange(0, left).setTo(0); likely.colRange(right, w).setTo(0); likely.rowRange(0, top).setTo(0);
        labels.setTo(cv::GC_PR_FGD, likely);
        cv::erode(seed, seed, ellipse(11));
        labels.setTo(cv::GC_FGD, seed);
    }
    cv::Mat bgModel, fgModel;
    cv::grabCut(photo, labels, {}, bgModel, fgModel, 4, cv::GC_INIT_WITH_MASK);
    cv::Mat binary = (labels == cv::GC_FGD) | (labels == cv::GC_PR_FGD);
    if (edgeSubject) cv::bitwise_and(binary, depth > 0.45 * 65535, binary);
    binary = component(binary, 0.015, edgeSubject ? 0.35 : 0.55, edgeSubject);
    if (binary.empty()) return {};
    cv::Mat overlap; cv::bitwise_and(binary, seed, overlap);
    if (cv::countNonZero(overlap) < cv::countNonZero(seed) * (edgeSubject ? 0.9 : 0.65)) return {};
    if (edgeSubject) { auto box = cv::boundingRect(binary); if (box.width > w * 0.65 || box.y > h * 0.5) return {}; }
    cv::morphologyEx(binary, binary, cv::MORPH_CLOSE, ellipse(edgeSubject ? 11 : 3));
    restoreHoles(binary, depth);
    return binary;
}

cv::Mat maskFromModel(const cv::Mat &confidence, const cv::Mat &photo, const cv::Mat &depth, cv::Mat &alpha) {
    if (confidence.empty()) return {};
    // Salient subjects in wallpapers are often cropped at the output edges.
    // Keep them eligible; depth overlap still rejects unrelated components.
    cv::Mat proposed = component(confidence > 64, 0.005, 0.60, true, true);
    if (proposed.empty()) return {};
    cv::Mat strong = depth > 0.58 * 65535;
    strong.rowRange(int(photo.rows * 0.78), photo.rows).setTo(0);
    strong.colRange(0, int(photo.cols * 0.12)).setTo(0);
    strong.colRange(int(photo.cols * 0.88), photo.cols).setTo(0);
    strong = component(strong, 0.004, 0.22, false, true);
    if (strong.empty()) return {};
    cv::Mat overlap; cv::bitwise_and(strong, proposed, overlap);
    if (cv::countNonZero(overlap) < cv::countNonZero(strong) * 0.55) return {};
    cv::Mat repair = segmentDepth(photo, depth, false);
    if (repair.empty()) repair = segmentDepth(photo, depth, true);
    cv::Mat support, vicinity;
    if (!repair.empty()) {
        cv::dilate(proposed, vicinity, ellipse(31));
        cv::bitwise_and(repair, vicinity, support);
        cv::bitwise_or(proposed, support, proposed);
    }
    cv::Mat before = proposed.clone(), holes, allowed;
    restoreHoles(proposed, depth);
    cv::subtract(proposed, before, holes);
    cv::dilate(proposed, allowed, ellipse(17));
    alpha = cv::Mat::zeros(photo.size(), CV_8U);
    confidence.copyTo(alpha, allowed);
    if (!support.empty()) alpha.setTo(255, support);
    alpha.setTo(255, holes);
    // IS-Net Anime confidence can be low across a solid face or clothing even when
    // its subject component is reliable. Confidence controls only the outer
    // contour; the interior must be opaque to avoid exposing reconstructed
    // background through the subject.
    cv::Mat interior;
    cv::erode(proposed, interior, ellipse(11));
    alpha.setTo(255, interior);
    cv::GaussianBlur(alpha, alpha, {}, 0.7);
    return proposed;
}

cv::Mat backgroundFill(const cv::Mat &photo, const cv::Mat &mask) {
    cv::Mat hidden, distance, labels;
    int radius = std::max(12, int(std::lround(std::min(photo.cols, photo.rows) * 0.012)));
    cv::dilate(mask, hidden, ellipse(radius * 2 + 1));
    cv::distanceTransform(hidden, distance, labels, cv::DIST_L2, 5, cv::DIST_LABEL_PIXEL);
    double maxLabel; cv::minMaxLoc(labels, nullptr, &maxLabel);
    std::vector<cv::Point> nearest(size_t(maxLabel) + 1, {-1, -1});
    for (int y=0; y<photo.rows; ++y) for (int x=0; x<photo.cols; ++x)
        if (!hidden.at<uchar>(y,x)) nearest.at(labels.at<int>(y,x)) = {x,y};
    cv::Mat filled = photo.clone();
    for (int y=0; y<photo.rows; ++y) for (int x=0; x<photo.cols; ++x) {
        if (!hidden.at<uchar>(y,x)) continue;
        auto p = nearest.at(labels.at<int>(y,x));
        if (p.x < 0) continue;
        cv::Point reflected(2*p.x-x, 2*p.y-y);
        if (reflected.x>=0 && reflected.y>=0 && reflected.x<photo.cols && reflected.y<photo.rows && !hidden.at<uchar>(reflected)) p=reflected;
        filled.at<cv::Vec3b>(y,x) = photo.at<cv::Vec3b>(p);
    }
    cv::Mat blurred, blendMask, out(photo.size(), photo.type());
    cv::GaussianBlur(filled, blurred, {}, 2.0); cv::GaussianBlur(hidden, blendMask, {}, 1.4);
    for (int y=0; y<photo.rows; ++y) for (int x=0; x<photo.cols; ++x) {
        double a = blendMask.at<uchar>(y,x) / 255.0;
        auto original = photo.at<cv::Vec3b>(y,x), replacement = blurred.at<cv::Vec3b>(y,x);
        auto &dest = out.at<cv::Vec3b>(y,x);
        for (int c=0; c<3; ++c) dest[c] = cv::saturate_cast<uchar>(original[c]*(1-a)+replacement[c]*a);
    }
    return out;
}

cv::Mat influenceMap(const cv::Mat &depth, const cv::Mat &mask) {
    cv::Mat near; cv::bitwise_and(depth > 0.82 * 65535, mask, near);
    near = component(near, 0.001, 0.30);
    if (near.empty()) return cv::Mat::zeros(depth.size(), CV_8U);
    cv::dilate(near, near, ellipse(101)); cv::GaussianBlur(near, near, {}, 25.0); return near;
}

}

int main(int argc, char **argv) {
    if (argc != 8) { std::cerr << "usage: depthscape-spatial-assets photo.png depth.png model.png|- background.png matte.png influence.png reserved\n"; return 2; }
    try {
        cv::Mat photo=cv::imread(argv[1],cv::IMREAD_COLOR), depth=cv::imread(argv[2],cv::IMREAD_UNCHANGED);
        cv::Mat model = std::string(argv[3]) == "-" ? cv::Mat() : cv::imread(argv[3],cv::IMREAD_GRAYSCALE);
        if (std::string(argv[3]) != "-" && model.empty()) throw std::runtime_error("cannot read foreground model confidence image");
        if (photo.empty() || depth.empty() || depth.type()!=CV_16UC1 || depth.size()!=photo.size() || (!model.empty() && model.size()!=photo.size())) throw std::runtime_error("invalid spatial asset input images");
        cv::Mat alpha, mask=maskFromModel(model,photo,depth,alpha);
        const bool usedModel = !mask.empty();
        if (mask.empty()) mask=segmentDepth(photo,depth,false);
        if (mask.empty()) mask=segmentDepth(photo,depth,true);
        if (mask.empty()) throw std::runtime_error("no suitable foreground subject was found");
        if (alpha.empty()) { cv::erode(mask,alpha,ellipse(3)); cv::GaussianBlur(alpha,alpha,{},0.9); }
        if (!cv::imwrite(argv[4],backgroundFill(photo,mask)) || !cv::imwrite(argv[5],alpha) || !cv::imwrite(argv[6],influenceMap(depth,mask))) throw std::runtime_error("could not write spatial assets");
        std::cout << (usedModel ? "isnet\n" : "depth\n");
        return 0;
    } catch (const std::exception &e) { std::cerr << "spatial asset preparation: " << e.what() << '\n'; return 1; }
}
