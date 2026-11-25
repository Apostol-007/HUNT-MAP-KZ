import SwiftUI
import UIKit

/// A single composited native canvas; cloud textures are baked once, not generated per frame.
struct NaturalWeatherPainter {
    let size: CGSize
    let time: Double
    let night: Bool
    let rainRate: Double
    let windSpeed: Double
    let windDirection: Double
    let motion: Bool
    private var w: Double { Double(size.width) }
    private var h: Double { Double(size.height) }
    private var drift: Double {
        sin(windDirection * .pi / 180) * min(75, max(0, windSpeed) * 0.9)
    }
    private func random(_ index: Int, _ salt: Int) -> Double {
        var x = UInt32(truncatingIfNeeded: index &* 374761393 &+ salt &* 668265263)
        x = (x ^ (x >> 13)) &* 1274126177
        return Double(x ^ (x >> 16)) / Double(UInt32.max)
    }
    private func wrap(_ x: Double, _ length: Double) -> Double {
        guard length > 0 else { return 0 }
        let n = x.truncatingRemainder(dividingBy: length)
        return n < 0 ? n + length : n
    }
    private func point(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x, y: y) }

    func clouds(_ context: GraphicsContext, fog: Bool, storm: Bool) {
        guard w > 0, h > 0 else { return }
        for layer in 0..<3 {
            let scale = 1.4 + Double(layer) * 0.35
            let width = w * scale
            let height = fog ? h * 0.80 : h * 1.25
            let speed = (2.5 + Double(layer) * 2) + drift * 0.15
            let offset = wrap(time * speed + Double(layer) * width * 0.37, width)
            var c = context
            c.opacity = fog ? 0.28 : (storm ? 0.27 : 0.20)
            let y = fog ? h * (0.25 + Double(layer) * 0.1) : -h * (0.35 - Double(layer) * 0.16)
            let image = Image(uiImage: CloudWeatherTexture.images[layer])
            for tile in -1...1 {
                let rect = CGRect(x: Double(tile) * width + offset - width * 0.5, y: y, width: width, height: height)
                c.draw(image, in: rect)
            }
        }
    }

    func rain(_ context: GraphicsContext) {
        guard w > 0, h > 0 else { return }
        let intensity = min(1, max(0.12, rainRate / 4))
        let count = Int(45 + intensity * 95)
        for layer in 0..<3 {
            let depth = Double(layer + 1) / 3
            var c = context
            if layer == 0 { c.addFilter(.blur(radius: 0.8)) }
            for i in 0..<count {
                let seed = i + layer * 1000
                let speed = (110 + random(seed, 11) * 110) * (0.65 + depth)
                let length = (6 + random(seed, 12) * 15) * depth
                let x = wrap(random(seed, 13) * (w + 70) + time * drift * depth, w + 70) - 35
                let y = wrap(random(seed, 14) * (h + 50) + time * speed, h + 50) - 25
                let start = point(x, y)
                let end = point(x + drift / speed * length, y + length)
                var path = Path()
                path.move(to: start)
                path.addLine(to: end)
                let alpha = (0.08 + random(seed, 15) * 0.22) * depth
                let gradient = Gradient(colors: [.clear, .white.opacity(alpha), .white.opacity(alpha * 0.5)])
                c.stroke(path, with: .linearGradient(gradient, startPoint: start, endPoint: end),
                    style: StrokeStyle(lineWidth: 0.45 + depth * 0.65, lineCap: .round))
            }
        }
        // Small transient droplets and splash ripples near the lower edge.
        if intensity > 0.35 {
            for i in 0..<10 {
                let phase = wrap(time * 0.8 + random(i, 61), 1)
                let r = 1.5 + phase * 5
                let x = random(i, 62) * w
                let y = h * (0.84 + random(i, 63) * 0.14)
                let ellipse = Path(ellipseIn: CGRect(x: x-r, y: y-r*0.22, width: r*2, height: r*0.44))
                context.stroke(ellipse, with: .color(.white.opacity((1-phase)*0.13)), lineWidth: 0.6)
            }
        }
    }

    func snow(_ context: GraphicsContext) {
        guard w > 0, h > 0 else { return }
        for layer in 0..<3 {
            let depth = Double(layer + 1) / 3
            var c = context
            if layer == 0 { c.addFilter(.blur(radius: 1.2)) }
            for i in 0..<30 {
                let seed = layer * 100 + i
                let speed = 9 + depth * 19 + random(seed, 21) * 12
                let sway = sin(time * (0.45 + random(seed, 22)) + random(seed, 23) * 6.28) * (5 + depth * 9)
                let x = wrap(random(seed, 24) * (w+40) + time * drift * 0.35 + sway, w+40) - 20
                let y = wrap(random(seed, 25) * (h+24) + time * speed, h+24) - 12
                let r = 0.55 + random(seed, 26) * depth * 2.1
                let rect = CGRect(x: x-r, y: y-r, width: 2*r, height: 2*r)
                c.fill(Path(ellipseIn: rect), with: .color(.white.opacity(0.16 + depth * 0.42)))
                if layer == 2 && r > 1.8 {
                    var flake = Path()
                    for arm in 0..<3 {
                        let angle = Double(arm) * .pi / 3 + time * 0.18 + random(seed, 27) * .pi
                        let dx = cos(angle) * r * 1.45, dy = sin(angle) * r * 1.45
                        flake.move(to: point(x-dx, y-dy))
                        flake.addLine(to: point(x+dx, y+dy))
                    }
                    c.stroke(flake, with: .color(.white.opacity(0.38)), lineWidth: 0.5)
                }
            }
        }
    }

    func wind(_ context: GraphicsContext) {
        guard w > 0, h > 0 else { return }
        let angle = windDirection * .pi / 180 - .pi / 2
        let dx = cos(angle), dy = sin(angle)
        for i in 0..<16 {
            let speed = 18 + min(85, windSpeed) * (0.7 + random(i, 31))
            let x = wrap(random(i, 32) * (w+100) + time*speed*dx, w+100)-50
            let y = wrap(random(i, 33) * (h+100) + time*speed*dy, h+100)-50
            let length = 18 + random(i, 34)*36
            let start = point(x,y)
            let end = point(x+dx*length,y+dy*length)
            var curve = Path()
            curve.move(to: start)
            curve.addQuadCurve(to: end, control: point(x+dx*length*0.5-dy*5,y+dy*length*0.5+dx*5))
            context.stroke(curve, with: .linearGradient(Gradient(colors: [.clear,.white.opacity(0.19),.clear]), startPoint: start,endPoint: end), style: StrokeStyle(lineWidth: 0.8,lineCap: .round))
        }
    }

    func celestial(_ context: GraphicsContext) {
        guard w > 0, h > 0 else { return }
        let center = point(w*0.78,h*0.20)
        if night {
            for i in 0..<52 {
                let x = random(i,41)*w, y = random(i,42)*h
                let radius = 0.35 + random(i,43)*0.85
                let alpha = 0.16 + 0.4 * (1+sin(time*(0.35+random(i,44)*0.8)+Double(i)))/2
                context.fill(Path(ellipseIn: CGRect(x:x,y:y,width:radius*2,height:radius*2)), with:.color(.white.opacity(alpha)))
            }
        }
        let r = min(w,h) * (night ? 0.095 : 0.13)
        let halo = r * (3.2 + 0.10*sin(time*0.4))
        let glow = Path(ellipseIn: CGRect(x:center.x-halo,y:center.y-halo,width:halo*2,height:halo*2))
        let tint: Color = night ? .white : Color(red:1,green:0.85,blue:0.57)
        context.fill(glow,with:.radialGradient(Gradient(colors:[tint.opacity(0.36),tint.opacity(0.09),.clear]),center:center,startRadius:0,endRadius:halo))
        let disc = Path(ellipseIn: CGRect(x:center.x-r,y:center.y-r,width:r*2,height:r*2))
        context.fill(disc,with:.radialGradient(Gradient(colors:[.white.opacity(0.86),tint.opacity(0.64)]),center:point(center.x-r*0.3,center.y-r*0.3),startRadius:0,endRadius:r*1.4))
        if night {
            var c = context
            c.clip(to: disc)
            for i in 0..<8 {
                let cr = r*(0.08+random(i,45)*0.22)
                let x = center.x+(random(i,46)-0.5)*r*1.7
                let y = center.y+(random(i,47)-0.5)*r*1.7
                c.fill(Path(ellipseIn:CGRect(x:x-cr,y:y-cr,width:cr*2,height:cr*2)),with:.color(.black.opacity(0.12)))
            }
        }
    }

    func lightning(_ context: GraphicsContext) {
        guard motion, w > 0, h > 0 else { return }
        let event = floor(time / 19)
        let phase = wrap(time,19)
        guard phase > 2.0 && phase < 2.65 else { return }
        let fade = max(0,1-abs(phase-2.24)/0.41)
        let seed = Int(event.truncatingRemainder(dividingBy: 100000))
        let origin = w*(0.48+random(seed,51)*0.36)
        var path = Path()
        path.move(to:point(origin,-8))
        var x = origin
        for j in 1...7 {
            x += (random(seed+j,52)-0.5)*w*0.13
            path.addLine(to:point(x,Double(j)*h*0.095))
        }
        var glow = context
        glow.addFilter(.blur(radius: 4))
        glow.stroke(path,with:.color(.white.opacity(fade*0.22)),lineWidth:5)
        context.stroke(path,with:.color(.white.opacity(fade*0.65)),style:StrokeStyle(lineWidth:0.8,lineCap:.round,lineJoin:.round))
    }
}

/// Tileable multi-octave value noise gives irregular cloud bodies and soft edges.
/// Three 256x128 textures are cached for the lifetime of the process.
private enum CloudWeatherTexture {
    static let images: [UIImage] = (0..<3).map { make(seed: $0 + 17) }
    private static func hash(_ x:Int,_ y:Int,_ seed:Int)->Double {
        var n = UInt32(truncatingIfNeeded: x &* 374761393 &+ y &* 668265263 &+ seed &* 1274126177)
        n = (n ^ (n >> 13)) &* 1274126177
        return Double(n ^ (n >> 16))/Double(UInt32.max)
    }
    private static func noise(_ x:Double,_ y:Double,_ cells:Int,_ seed:Int)->Double {
        let ix = Int(floor(x)), iy = Int(floor(y))
        let fx = x-Double(ix), fy = y-Double(iy)
        let u = fx*fx*(3-2*fx), v = fy*fy*(3-2*fy)
        let a = hash(ix % cells,iy,seed), b = hash((ix+1) % cells,iy,seed)
        let c = hash(ix % cells,iy+1,seed), d = hash((ix+1) % cells,iy+1,seed)
        return (a+(b-a)*u)*(1-v)+(c+(d-c)*u)*v
    }
    private static func make(seed:Int)->UIImage {
        let width=256, height=128
        var bytes=[UInt8](repeating:0,count:width*height*4)
        for y in 0..<height {
            let ny=Double(y)/Double(height)
            let edge=pow(max(0,sin(ny*Double.pi)),0.65)
            for x in 0..<width {
                let nx=Double(x)/Double(width)
                var value=0.0, weight=0.55
                for octave in 0..<5 {
                    let cells=4 << octave
                    value += noise(nx*Double(cells),ny*Double(cells)*0.55,cells,seed+octave*13)*weight
                    weight *= 0.5
                }
                let density=min(1,max(0,(value-0.29)*2.5))*edge
                let alpha=UInt8(min(255,max(0,density*210)))
                let luminance=UInt8(Double(alpha)*(0.65+0.35*value))
                let i=(y*width+x)*4
                bytes[i]=luminance; bytes[i+1]=luminance; bytes[i+2]=luminance; bytes[i+3]=alpha
            }
        }
        let data=Data(bytes) as CFData
        guard let provider=CGDataProvider(data:data),
              let image=CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:width*4,
                space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),
                provider:provider,decode:nil,shouldInterpolate:true,intent:.defaultIntent) else { return UIImage() }
        return UIImage(cgImage:image)
    }
}
