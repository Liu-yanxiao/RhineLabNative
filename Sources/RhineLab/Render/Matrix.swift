import simd

/// Right-handed matrices with Metal clip space (z in 0...1).
enum Matrix {
    static func lookAt(eye: SIMD3<Float>, target: SIMD3<Float>, up: SIMD3<Float>) -> float4x4 {
        let z = simd_normalize(eye - target)
        let x = simd_normalize(simd_cross(up, z))
        let y = simd_cross(z, x)
        return float4x4(columns: (
            SIMD4(x.x, y.x, z.x, 0), SIMD4(x.y, y.y, z.y, 0), SIMD4(x.z, y.z, z.z, 0),
            SIMD4(-simd_dot(x, eye), -simd_dot(y, eye), -simd_dot(z, eye), 1)))
    }

    static func perspective(fovY: Float, aspect: Float, near: Float, far: Float) -> float4x4 {
        let f = 1 / tan(fovY / 2)
        return float4x4(columns: (
            SIMD4(f / aspect, 0, 0, 0), SIMD4(0, f, 0, 0),
            SIMD4(0, 0, far / (near - far), -1), SIMD4(0, 0, near * far / (near - far), 0)))
    }

    static func orthographic(left l: Float, right r: Float, bottom b: Float, top t: Float, near n: Float, far f: Float) -> float4x4 {
        float4x4(columns: (
            SIMD4(2 / (r - l), 0, 0, 0), SIMD4(0, 2 / (t - b), 0, 0), SIMD4(0, 0, 1 / (n - f), 0),
            SIMD4(-(r + l) / (r - l), -(t + b) / (t - b), n / (n - f), 1)))
    }

    /// Rotation used for cards: x tilt applied after the y turn (Euler XYZ order).
    static func rotationXY(tilt: Float, yaw: Float) -> float3x3 {
        let cx = cos(tilt), sx = sin(tilt), cy = cos(yaw), sy = sin(yaw)
        let rx = float3x3(columns: (SIMD3(1, 0, 0), SIMD3(0, cx, sx), SIMD3(0, -sx, cx)))
        let ry = float3x3(columns: (SIMD3(cy, 0, -sy), SIMD3(0, 1, 0), SIMD3(sy, 0, cy)))
        return rx * ry
    }
}

/// What the renderer needs to draw one frame.
struct CardDraw {
    var position: SIMD3<Float>
    var tilt: Float
    var yaw: Float
    var quality: Float      // 0 = resting in the array, 1 = extracted
    var reveal: Float       // glass-clearing sweep, 0 frosted ... 1 clear
    var labelIndex: Int
    var theme: Float = 0    // 0 light materials ... 1 dark materials
}

/// The exploded assembly shown by the 360° viewer instead of the archive.
struct AssemblyDraw {
    var spread: Float       // 0 = assembled, 1 = parts spread along the thickness axis
    var clarity: Float      // 0 = frosted cover, 1 = clear
    var labelIndex: Int
    var theme: Float = 0
}

struct RenderFrame {
    var view = matrix_identity_float4x4
    var proj = matrix_identity_float4x4
    var cameraPosition = SIMD3<Float>(0, 0, 0)
    var fogNear: Float = 0
    var fogFar: Float = 1
    /// xyz = position, w = tilt about X, one per visible array card.
    var arrayCards: [SIMD4<Float>] = []
    /// Dark-theme amount per array card, parallel to `arrayCards` (empty = all light).
    var arrayTheme: [Float] = []
    var cards: [CardDraw] = []
    /// When set, the assembly is drawn alone (no floor, array or extracted cards).
    var assembly: AssemblyDraw? = nil
    /// Background colour as displayed (sRGB 0...1); the renderer solves the linear value.
    var background = SIMD3<Float>(231, 228, 223) / 255
    /// Fog colour as displayed; nil follows the background.
    var fogColor: SIMD3<Float>? = nil
    /// Dark-theme amount for lighting, exposure and the floor (0 light ... 1 dark).
    var themeAmount: Float = 0
    var focusDistance: Float = 100
    var depthOfField: Float = 0     // 0 = off, 1 = original lens
    var near: Float = 10
    var far: Float = 300
    var detail: Float = 0
    /// Bit 2 = skip ambient occlusion, bit 4 = skip depth of field (used by adaptive quality).
    var effectsOff: Int = 0
    var time: Float = 0
}
