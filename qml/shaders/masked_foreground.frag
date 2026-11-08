#version 440
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;
layout(binding = 1) uniform sampler2D source;
layout(binding = 2) uniform sampler2D maskSource;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec2 cropScale;
    vec4 subRect;
} ubuf;

void main() {
    vec2 parentUv = ubuf.subRect.xy + qt_TexCoord0 * ubuf.subRect.zw;
    vec2 uv = vec2(0.5) + (parentUv - vec2(0.5)) * ubuf.cropScale;
    float a = texture(maskSource, uv).a;
    if (a <= 0.001) {
        discard;
    }
    vec4 src = texture(source, uv);
    fragColor = vec4(src.rgb * a, a) * ubuf.qt_Opacity;
}
