VARYING vec2 meshUv;
void MAIN() {
    vec2 d = 1.5 / vec2(textureSize(backgroundTexture, 0));
    vec3 c = texture(backgroundTexture, meshUv).rgb * 0.25;
    c += (texture(backgroundTexture, meshUv + vec2(d.x, 0)).rgb + texture(backgroundTexture, meshUv - vec2(d.x, 0)).rgb + texture(backgroundTexture, meshUv + vec2(0, d.y)).rgb + texture(backgroundTexture, meshUv - vec2(0, d.y)).rgb) * 0.125;
    c += (texture(backgroundTexture, meshUv + d).rgb + texture(backgroundTexture, meshUv - d).rgb + texture(backgroundTexture, meshUv + vec2(d.x, -d.y)).rgb + texture(backgroundTexture, meshUv + vec2(-d.x, d.y)).rgb) * 0.0625;
    FRAGCOLOR = vec4(c, 1.0);
}
