#version 440
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;
layout(binding = 1) uniform sampler2D source;
layout(binding = 2) uniform sampler2D background;
layout(binding = 3) uniform sampler2D matte;
layout(binding = 4) uniform sampler2D influence;
layout(binding = 5) uniform sampler2D depthMap;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec2 pointer;
    vec2 cropScale;
    vec2 backgroundTexel;
    float foregroundOnly;
    float imageZoom;
} ubuf;

void main() {
    vec2 screen = (qt_TexCoord0 - vec2(0.5)) * 2.0;
    // Same enlargement the native mesh uses, so both paths frame alike.
    vec2 uv = vec2(0.5) + screen * ubuf.cropScale * (0.5 / ubuf.imageZoom);
    vec2 sphere = screen * 0.42;
    float sphereZ = sqrt(max(0.01, 1.0 - dot(sphere, sphere)));
    float yaw = ubuf.pointer.x * 0.075;
    float pitch = -ubuf.pointer.y * 0.055;
    float cy = cos(yaw);
    float sy = sin(yaw);
    float cp = cos(pitch);
    float sp = sin(pitch);
    float turnedX = sphere.x * cy + sphereZ * sy;
    float turnedZ = -sphere.x * sy + sphereZ * cy;
    float turnedY = sphere.y * cp - turnedZ * sp;
    vec2 orbit = (vec2(turnedX, turnedY) - sphere) * 0.28;

    float depth = texture(depthMap, uv).r;
    float foreground = texture(matte, uv).r;
    float nearInfluence = texture(influence, uv).r;
    float farWeight = 1.0 - smoothstep(0.30, 0.72, depth);
    farWeight = max(farWeight, foreground);
    farWeight *= 1.0 - nearInfluence * 0.35;
    vec2 bgUv = clamp(uv + orbit * farWeight * ubuf.cropScale,
        vec2(0.001), vec2(0.999));
    vec2 fgUv = clamp(uv - ubuf.pointer * ubuf.cropScale * 0.005,
        vec2(0.001), vec2(0.999));
    float alpha = texture(matte, fgUv).r;
    vec3 fg = texture(source, fgUv).rgb;

    if (ubuf.foregroundOnly > 0.5) {
        vec3 color = fg * alpha;
        if (alpha > 0.08 && alpha < 0.98) {
            vec3 reference = texture(background, fgUv).rgb;
            vec3 recovered = clamp(fg - reference * (1.0 - alpha), vec3(0.0), vec3(alpha));
            float limit = 0.18 * alpha;
            recovered = clamp(recovered, color - vec3(limit), color + vec3(limit));
            float weight = smoothstep(0.08, 0.30, alpha) * (1.0 - smoothstep(0.82, 0.98, alpha));
            color = mix(color, recovered, 0.75 * weight);
        }
        fragColor = vec4(color, alpha) * ubuf.qt_Opacity;
        return;
    }

    vec2 px = 1.25 * ubuf.backgroundTexel;
    vec3 bg = texture(background, bgUv).rgb * 0.25;
    bg += texture(background, bgUv + vec2(px.x, 0)).rgb * 0.125;
    bg += texture(background, bgUv - vec2(px.x, 0)).rgb * 0.125;
    bg += texture(background, bgUv + vec2(0, px.y)).rgb * 0.125;
    bg += texture(background, bgUv - vec2(0, px.y)).rgb * 0.125;
    bg += texture(background, bgUv + px).rgb * 0.0625;
    bg += texture(background, bgUv - px).rgb * 0.0625;
    bg += texture(background, bgUv + vec2(px.x, -px.y)).rgb * 0.0625;
    bg += texture(background, bgUv + vec2(-px.x, px.y)).rgb * 0.0625;
    fragColor = vec4(bg, 1.0) * ubuf.qt_Opacity;
}
