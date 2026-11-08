VARYING vec2 meshUv;
void MAIN() {
    meshUv = UV0;
    POSITION = MODELVIEWPROJECTION_MATRIX * vec4(VERTEX, 1.0);
}
