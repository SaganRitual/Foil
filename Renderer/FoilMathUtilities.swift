import simd

func generate_random_vector(min: Float, max: Float) -> vector_float3 {
    let range = max - min;

    let x = Float.random(in: 0..<1) * range + min;
    let y = Float.random(in: 0..<1) * range + min;
    let z = Float.random(in: 0..<1) * range + min;

    return vector_float3(x, y, z)
}

func matrix_ortho_left_hand(
    left: Float, right: Float, bottom: Float, top: Float, nearZ: Float, farZ: Float
) -> matrix_float4x4 {
    return matrix_make_rows(
        2 / (right - left),                  0,                  0, (left + right) / (left - right),
                         0, 2 / (top - bottom),                  0, (top + bottom) / (bottom - top),
                         0,                  0, 1 / (farZ - nearZ),          nearZ / (nearZ - farZ),
                         0,                  0,                  0,                               1 );
}

func matrix_make_rows(
    _ m00: Float, _ m10: Float, _ m20: Float, _ m30: Float,
    _ m01: Float, _ m11: Float, _ m21: Float, _ m31: Float,
    _ m02: Float, _ m12: Float, _ m22: Float, _ m32: Float,
    _ m03: Float, _ m13: Float, _ m23: Float, _ m33: Float
) -> matrix_float4x4 {
    return matrix_float4x4([
        [ m00, m01, m02, m03 ],     // each line here provides column data
        [ m10, m11, m12, m13 ],
        [ m20, m21, m22, m23 ],
        [ m30, m31, m32, m33 ] ] )
}
