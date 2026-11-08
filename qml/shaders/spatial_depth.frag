#version 440
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;
layout(binding = 1) uniform sampler2D source;
layout(binding = 2) uniform sampler2D depthMap;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec2 pointer;
    vec2 cropScale;
} ubuf;

void main() {
    vec2 uv = vec2(0.5) + (qt_TexCoord0 - vec2(0.5)) * ubuf.cropScale * 0.92;
    float depth = texture(depthMap, uv).r;
    float farWeight = 1.0 - smoothstep(0.12, 0.90, depth);
    vec2 scene = (qt_TexCoord0 - vec2(0.5)) * 0.42;
    float z = sqrt(max(0.02, 1.0 - dot(scene, scene)));
    float yaw = ubuf.pointer.x * 0.075;
    float pitch = -ubuf.pointer.y * 0.055;
    vec2 orbit = vec2(z * sin(yaw), z * sin(pitch)) * 0.30;
    vec2 sampleUv = clamp(uv + orbit * farWeight * ubuf.cropScale,
        vec2(0.005), vec2(0.995));
    fragColor = texture(source, sampleUv) * ubuf.qt_Opacity;
}
