VARYING vec2 meshUv;
void MAIN() {
    vec3 source = texture(sourceTexture, meshUv).rgb;
    float alpha = texture(matteTexture, meshUv).r;
    vec3 color = source * alpha;
    if (alpha > 0.08 && alpha < 0.98) {
        vec3 bg = texture(backgroundTexture, meshUv).rgb;
        vec3 recovered = clamp(source - bg * (1.0 - alpha), vec3(0.0), vec3(alpha));
        float limit = 0.18 * alpha;
        recovered = clamp(recovered, color - vec3(limit), color + vec3(limit));
        float weight = smoothstep(0.08, 0.30, alpha) * (1.0 - smoothstep(0.82, 0.98, alpha));
        color = mix(color, recovered, 0.75 * weight);
    }
    FRAGCOLOR = vec4(color, alpha);
}
