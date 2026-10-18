// Photogramme : sortir une photo en pleine qualité d'une vidéo, cadrée au format voulu.
// L'image est lue dans le fichier par AVFoundation (image exacte, résolution native), jamais dans l'aperçu.
// Compilation : voir build.sh (swiftc, sans Xcode).
import SwiftUI
import AVKit
import AVFoundation
import UniformTypeIdentifiers

// Jaune de la marque gaelcreates, en touche : bouton principal, sélection, interrupteurs, tête de lecture.
let accent = Color(red: 1, green: 197 / 255, blue: 8 / 255)

@main
struct PhotogrammeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        Window("Photogramme", id: "main") {
            RootView()
                .environmentObject(Model.shared)
                .tint(accent)
                .frame(minWidth: 960, minHeight: 640)
        }
        .defaultSize(width: 1240, height: 800)
        .windowToolbarStyle(.unified)
        .commands { AppCommands(m: Model.shared) }
    }
}

// Menus : observent le modèle pour s'activer dès qu'une vidéo est ouverte.
struct AppCommands: Commands {
    @ObservedObject var m: Model
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Ouvrir…") { m.choose() }.keyboardShortcut("o")
        }
        CommandGroup(after: .newItem) {
            Button("Exporter la photo") { m.capture() }
                .keyboardShortcut("e")
                .disabled(m.player == nil || m.busy)
            Button("Copier la dernière photo") { m.copyLast() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(m.lastSaved == nil)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let a = CommandLine.arguments
        // Mode test : Photogramme --test video.mp4 secondes format dossier [exact]
        if a.count >= 6, a[1] == "--test" {
            let ratio = Ratio(rawValue: a[4]) ?? .story
            Task {
                do {
                    let out = try await Model.headless(url: URL(fileURLWithPath: a[2]), time: Double(a[3]) ?? 0, ratio: ratio,
                                                       dir: URL(fileURLWithPath: a[5]), sharpest: a.count < 7)
                    print(out.path); exit(0)
                } catch { print("ERREUR \(error)"); exit(1) }
            }
            return
        }
        // Mode capture d'écran de l'interface : Photogramme --snapshot video.mp4 sortie.png
        if a.count >= 4, a[1] == "--snapshot" {
            Task { @MainActor in
                Model.shared.stillPreview = true
                Model.shared.load(URL(fileURLWithPath: a[2]))
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                Model.shared.seek(Model.shared.duration * 0.42)
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if let w = NSApp.windows.first(where: { $0.isVisible }), let v = w.contentView?.superview ?? w.contentView,
                   let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                    v.cacheDisplay(in: v.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: a[3]))
                }
                exit(0)
            }
            return
        }
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            MainActor.assumeIsolated {
                let m = Model.shared
                guard m.player != nil, !(NSApp.keyWindow?.firstResponder is NSText) else { return e }
                let shift = e.modifierFlags.contains(.shift)
                switch e.keyCode {
                case 123: shift ? m.jump(-1) : m.step(-1); return nil
                case 124: shift ? m.jump(1) : m.step(1); return nil
                case 49: m.toggle(); return nil
                default: return e
                }
            }
        }
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let u = urls.first else { return }
        Task { @MainActor in Model.shared.load(u) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

// MARK: - Formats

enum Ratio: String, CaseIterable, Identifiable {
    case original = "Original", story = "9:16", portrait = "4:5", carre = "1:1", paysage = "16:9"
    var id: String { rawValue }
    var value: CGFloat? {
        switch self {
        case .original: return nil
        case .story: return 9.0 / 16.0
        case .portrait: return 4.0 / 5.0
        case .carre: return 1
        case .paysage: return 16.0 / 9.0
        }
    }
    var label: String {
        switch self {
        case .original: return "Original"
        case .story: return "Story"
        case .portrait: return "Portrait"
        case .carre: return "Carré"
        case .paysage: return "Paysage"
        }
    }
    var short: String {
        switch self {
        case .original: return "original"
        case .story: return "9x16"
        case .portrait: return "4x5"
        case .carre: return "1x1"
        case .paysage: return "16x9"
        }
    }
}

enum OutFormat: String, CaseIterable, Identifiable {
    case jpeg = "JPEG", png = "PNG", heic = "HEIC"
    var id: String { rawValue }
    var ext: String { self == .jpeg ? "jpg" : rawValue.lowercased() }
    var type: UTType { self == .jpeg ? .jpeg : self == .png ? .png : .heic }
}

// MARK: - Modèle

@MainActor
final class Model: ObservableObject {
    static let shared = Model()
    @Published var url: URL?
    @Published var player: AVPlayer?
    @Published var size: CGSize = .zero
    @Published var duration: Double = 0
    @Published var time: Double = 0
    @Published var fps: Double = 30
    @Published var playing = false
    @Published var ratio: Ratio { didSet { UserDefaults.standard.set(ratio.rawValue, forKey: "ratio"); clampCenter() } }
    @Published var zoom: Double = 1 { didSet { clampCenter() } }
    @Published var center = CGPoint(x: 0.5, y: 0.5)
    @Published var sharpest: Bool { didSet { UserDefaults.standard.set(sharpest, forKey: "sharpest") } }
    @Published var format: OutFormat { didSet { UserDefaults.standard.set(format.rawValue, forKey: "format") } }
    @Published var folder: URL { didSet { UserDefaults.standard.set(folder.path, forKey: "folder") } }
    @Published var busy = false
    @Published var lastSaved: URL?
    @Published var lastImage: NSImage?
    @Published var message: String?
    @Published var toast: String?
    @Published var dropTargeted = false
    @Published var dragging = false
    @Published var showInspector = true
    @Published var filmstrip: [CGImage] = []
    @Published var stillPreview = false
    @Published var still: CGImage?
    var dragStart: CGPoint?
    private var asset: AVURLAsset?
    private var observer: Any?

    init() {
        let d = UserDefaults.standard
        ratio = Ratio(rawValue: d.string(forKey: "ratio") ?? "") ?? .original
        sharpest = d.object(forKey: "sharpest") as? Bool ?? true
        format = OutFormat(rawValue: d.string(forKey: "format") ?? "") ?? .jpeg
        let def = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0].appendingPathComponent("Photogramme", isDirectory: true)
        folder = d.string(forKey: "folder").map { URL(fileURLWithPath: $0, isDirectory: true) } ?? def
    }

    var videoName: String { url?.deletingPathExtension().lastPathComponent ?? "Photogramme" }
    var videoInfo: String {
        guard size.width > 0 else { return "" }
        let fr = fps.rounded() == fps ? String(Int(fps)) : String(format: "%.2f", fps)
        return "\(Int(size.width)) × \(Int(size.height)) · \(fr) i/s"
    }

    func choose() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.movie]
        p.allowsMultipleSelection = false
        if p.runModal() == .OK, let u = p.url { load(u) }
    }

    func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseFiles = false
        p.canChooseDirectories = true
        p.canCreateDirectories = true
        p.directoryURL = folder
        p.prompt = "Choisir"
        if p.runModal() == .OK, let u = p.url { folder = u }
    }

    func load(_ u: URL) {
        Task {
            do {
                let a = AVURLAsset(url: u, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
                guard let track = try await a.loadTracks(withMediaType: .video).first else {
                    message = "Ce fichier ne contient pas de vidéo."
                    return
                }
                let (nat, tf, rate) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate)
                let r = CGRect(origin: .zero, size: nat).applying(tf)
                let d = try await a.load(.duration).seconds
                if let o = observer { player?.removeTimeObserver(o) }
                let p = AVPlayer(playerItem: AVPlayerItem(asset: a))
                observer = p.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] t in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.playing = self.player?.timeControlStatus == .playing
                        if self.playing { self.time = t.seconds }
                    }
                }
                asset = a
                url = u
                size = CGSize(width: abs(r.width).rounded(), height: abs(r.height).rounded())
                fps = rate > 0 ? Double(rate) : 30
                duration = d
                time = 0
                zoom = 1
                center = CGPoint(x: 0.5, y: 0.5)
                lastSaved = nil
                lastImage = nil
                message = nil
                filmstrip = []
                player = p
                if stillPreview { refreshStill() }
                filmstrip = await Model.makeFilmstrip(asset: a, duration: d, size: size)
            } catch {
                message = "Impossible d'ouvrir cette vidéo : \(error.localizedDescription)"
            }
        }
    }

    // Dernière image lisible : une image avant la fin exacte du fichier.
    var lastFrameTime: Double { max(0, duration - 1 / max(fps, 1)) }

    func seek(_ t: Double) {
        time = min(max(0, t), lastFrameTime)
        player?.seek(to: CMTime(seconds: time, preferredTimescale: 600_000), toleranceBefore: .zero, toleranceAfter: .zero)
        if stillPreview { refreshStill() }
    }

    func step(_ n: Int) { player?.pause(); playing = false; seek(time + Double(n) / fps) }
    func jump(_ s: Double) { player?.pause(); playing = false; seek(time + s) }

    func toggle() {
        guard let p = player else { return }
        if p.timeControlStatus == .playing { p.pause(); playing = false } else {
            if time >= duration - 0.05 { seek(0) }
            p.play(); playing = true
        }
    }

    private func refreshStill() {
        guard let a = asset else { return }
        let t = time
        Task {
            let g = AVAssetImageGenerator(asset: a)
            g.appliesPreferredTrackTransform = true
            g.maximumSize = CGSize(width: 1600, height: 1600)
            still = try? await g.image(at: CMTime(seconds: t, preferredTimescale: 600)).image
        }
    }

    func cropRect() -> CGRect { Model.crop(size: size, ratio: ratio, zoom: zoom, center: center) }

    nonisolated static func crop(size: CGSize, ratio: Ratio, zoom: Double, center: CGPoint) -> CGRect {
        let W = size.width, H = size.height
        guard W > 0, H > 0 else { return .zero }
        let r = ratio.value ?? W / H
        var w = W, h = W / r
        if h > H { h = H; w = H * r }
        w = (w * zoom).rounded(.down); h = (h * zoom).rounded(.down)
        let x = min(max(0, center.x * W - w / 2), W - w).rounded()
        let y = min(max(0, center.y * H - h / 2), H - h).rounded()
        return CGRect(x: x, y: y, width: w, height: h)
    }

    func clampCenter() {
        guard size.width > 0 else { return }
        let c = cropRect()
        let n = CGPoint(x: c.midX / size.width, y: c.midY / size.height)
        if abs(n.x - center.x) > 0.0001 || abs(n.y - center.y) > 0.0001 { center = n }
    }

    var timecode: String {
        let s = Int(time)
        let f = Int(((time - Double(s)) * fps).rounded(.down))
        return String(format: "%02d:%02d:%02d", s / 60, s % 60, f)
    }

    var lowRes: Bool { (ratio == .story || ratio == .portrait) && cropRect().width < 1080 }
    var outputLabel: String { let c = cropRect(); return "\(Int(c.width)) × \(Int(c.height)) px" }

    func capture() {
        guard let a = asset, let src = url, !busy else { return }
        busy = true
        message = nil
        player?.pause()
        let t = min(time, lastFrameTime), f = fps, c = cropRect(), s = sharpest, r = ratio, fmt = format, dir = folder
        Task {
            do {
                let out = try await Model.render(asset: a, time: t, fps: f, crop: c, sharpest: s, source: src, ratio: r, format: fmt, dir: dir)
                lastSaved = out
                lastImage = NSImage(contentsOf: out)
                showToast("Photo exportée")
            } catch {
                message = "Export impossible : \(error.localizedDescription)"
                showToast("Export impossible, voir le panneau de droite")
            }
            busy = false
        }
    }

    func copyLast() {
        guard let u = lastSaved else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        var items: [NSPasteboardWriting] = [u as NSURL]
        if let img = NSImage(contentsOf: u) { items.insert(img, at: 0) }
        pb.writeObjects(items)
        showToast("Photo copiée")
    }

    func showToast(_ s: String) {
        toast = s
        Task { try? await Task.sleep(nanoseconds: 2_200_000_000); if toast == s { toast = nil } }
    }

    nonisolated static func makeFilmstrip(asset: AVAsset, duration: Double, size: CGSize) async -> [CGImage] {
        let g = AVAssetImageGenerator(asset: asset)
        g.appliesPreferredTrackTransform = true
        g.maximumSize = CGSize(width: 240, height: 240)
        let n = 18
        var out: [CGImage] = []
        for i in 0..<n {
            let t = duration * (Double(i) + 0.5) / Double(n)
            if let img = try? await g.image(at: CMTime(seconds: t, preferredTimescale: 600)).image { out.append(img) }
        }
        return out
    }

    nonisolated static func headless(url: URL, time: Double, ratio: Ratio, dir: URL, sharpest: Bool) async throws -> URL {
        let a = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let track = try await a.loadTracks(withMediaType: .video).first else { throw fail("pas de piste vidéo") }
        let (nat, tf, rate) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate)
        let r = CGRect(origin: .zero, size: nat).applying(tf)
        let size = CGSize(width: abs(r.width).rounded(), height: abs(r.height).rounded())
        let c = crop(size: size, ratio: ratio, zoom: 1, center: CGPoint(x: 0.5, y: 0.5))
        return try await render(asset: a, time: time, fps: Double(rate), crop: c, sharpest: sharpest, source: url,
                                ratio: ratio, format: .jpeg, dir: dir)
    }

    nonisolated static func fail(_ s: String) -> NSError {
        NSError(domain: "Photogramme", code: 1, userInfo: [NSLocalizedDescriptionKey: s])
    }

    // Lit l'image exacte (et ses 2 voisines de chaque côté si demandé), garde la plus nette, recadre, enregistre.
    nonisolated static func render(asset: AVAsset, time: Double, fps: Double, crop: CGRect, sharpest: Bool,
                                   source: URL, ratio: Ratio, format: OutFormat, dir: URL) async throws -> URL {
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        gen.maximumSize = .zero
        var times = [time]
        if sharpest && fps > 0 { times += [-2, -1, 1, 2].map { time + Double($0) / fps } }
        var best: CGImage?
        var bestScore = -Double.infinity
        for t in times where t >= 0 {
            guard let full = try? await gen.image(at: CMTime(seconds: t, preferredTimescale: 600_000)).image,
                  let img = full.cropping(to: crop) else { continue }
            let score = times.count == 1 ? 0 : sharpness(img)
            if score > bestScore { bestScore = score; best = img }
        }
        guard let img = best else { throw fail("aucune image lisible à ce moment de la vidéo") }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let s = Int(time)
        let f = Int(((time - Double(s)) * fps).rounded(.down))
        let base = "\(source.deletingPathExtension().lastPathComponent) \(String(format: "%02d-%02d-%02d", s / 60, s % 60, f)) \(ratio.short)"
        var out = dir.appendingPathComponent(base + "." + format.ext)
        var n = 2
        while FileManager.default.fileExists(atPath: out.path) {
            out = dir.appendingPathComponent("\(base) \(n).\(format.ext)")
            n += 1
        }
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, format.type.identifier as CFString, 1, nil) else {
            throw fail("écriture impossible dans \(dir.path)")
        }
        let q: Double = format == .heic ? 0.95 : 1.0
        CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: q] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw fail("écriture impossible dans \(dir.path)") }
        return out
    }

    // Netteté : variance du laplacien sur une version réduite en niveaux de gris.
    nonisolated static func sharpness(_ img: CGImage) -> Double {
        let scale = min(1, 900 / Double(max(img.width, img.height)))
        let w = max(8, Int(Double(img.width) * scale)), h = max(8, Int(Double(img.height) * scale))
        var px = [UInt8](repeating: 0, count: w * h)
        let ok = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return 0 }
        var sum = 0.0, sum2 = 0.0, n = 0.0
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let i = y * w + x
                let l = 4 * Double(px[i]) - Double(px[i - 1]) - Double(px[i + 1]) - Double(px[i - w]) - Double(px[i + w])
                sum += l; sum2 += l * l; n += 1
            }
        }
        let m = sum / n
        return sum2 / n - m * m
    }
}

// MARK: - Vues

struct PlayerView: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.controlsStyle = .none
        v.videoGravity = .resizeAspect
        v.player = player
        return v
    }
    func updateNSView(_ v: AVPlayerView, context: Context) {
        if v.player !== player { v.player = player }
    }
}

struct RootView: View {
    @EnvironmentObject var m: Model
    var body: some View {
        Group {
            if let p = m.player {
                VStack(spacing: 0) {
                    Canvas(player: p)
                    Divider()
                    Transport()
                }
                .inspector(isPresented: $m.showInspector) {
                    Inspector().inspectorColumnWidth(min: 260, ideal: 280, max: 340)
                }
            } else {
                EmptyState()
            }
        }
        .navigationTitle(m.videoName)
        .navigationSubtitle(m.videoInfo)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { m.choose() } label: { Label("Ouvrir", systemImage: "folder") }
                    .help("Ouvrir une vidéo (⌘O)")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if m.player != nil {
                    Button { m.capture() } label: {
                        Label(m.busy ? "Export…" : "Exporter", systemImage: "camera.aperture")
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(.black)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(m.busy)
                    .help("Exporter l'image affichée en photo (⌘E)")
                    Button { m.showInspector.toggle() } label: { Label("Réglages", systemImage: "sidebar.right") }
                        .help("Afficher ou masquer les réglages")
                }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $m.dropTargeted) { providers in
            guard let pr = providers.first else { return false }
            _ = pr.loadObject(ofClass: URL.self) { url, _ in
                if let url { Task { @MainActor in Model.shared.load(url) } }
            }
            return true
        }
    }
}

struct EmptyState: View {
    @EnvironmentObject var m: Model
    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text("Déposer une vidéo ici")
                .font(.title2.weight(.semibold))
            Text("MOV ou MP4. Le 4K est recommandé pour les formats verticaux.")
                .foregroundStyle(.secondary)
            Button { m.choose() } label: { Text("Ouvrir une vidéo…").foregroundStyle(.black) }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 6)
            if let msg = m.message { Text(msg).foregroundStyle(.red).padding(.top, 4) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(m.dropTargeted ? accent : Color.secondary.opacity(0.25),
                              style: StrokeStyle(lineWidth: m.dropTargeted ? 2 : 1.5, dash: [7, 6]))
                .padding(24)
        )
    }
}

struct Canvas: View {
    @EnvironmentObject var m: Model
    let player: AVPlayer
    var body: some View {
        GeometryReader { geo in
            let vr = videoRect(in: geo.size)
            let cr = displayCrop(vr)
            ZStack(alignment: .topLeading) {
                Color.black
                if m.stillPreview, let s = m.still {
                    Image(decorative: s, scale: 1).resizable().frame(width: vr.width, height: vr.height).offset(x: vr.minX, y: vr.minY)
                } else {
                    PlayerView(player: player)
                }
                Path { p in p.addRect(vr); p.addRect(cr) }
                    .fill(Color.black.opacity(0.58), style: FillStyle(eoFill: true))
                    .allowsHitTesting(false)
                if m.dragging {
                    Path { p in
                        for i in 1...2 {
                            let x = cr.minX + cr.width * CGFloat(i) / 3
                            let y = cr.minY + cr.height * CGFloat(i) / 3
                            p.move(to: CGPoint(x: x, y: cr.minY)); p.addLine(to: CGPoint(x: x, y: cr.maxY))
                            p.move(to: CGPoint(x: cr.minX, y: y)); p.addLine(to: CGPoint(x: cr.maxX, y: y))
                        }
                    }
                    .stroke(Color.white.opacity(0.35), lineWidth: 0.5)
                    .allowsHitTesting(false)
                }
                CropFrame()
                    .frame(width: cr.width, height: cr.height)
                    .offset(x: cr.minX, y: cr.minY)
                    .gesture(
                        DragGesture()
                            .onChanged { g in
                                if m.dragStart == nil { m.dragStart = m.center; m.dragging = true }
                                guard let s = m.dragStart, vr.width > 0 else { return }
                                m.center = CGPoint(x: s.x + g.translation.width / vr.width, y: s.y + g.translation.height / vr.height)
                                m.clampCenter()
                            }
                            .onEnded { _ in m.dragStart = nil; m.dragging = false }
                    )
                if let t = m.toast {
                    Label { Text(t) } icon: { Image(systemName: "checkmark.circle.fill").foregroundStyle(accent) }
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                        .frame(maxWidth: .infinity)
                        .padding(.top, 14)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.2), value: m.toast)
        }
    }

    func videoRect(in s: CGSize) -> CGRect {
        let pad: CGFloat = 24
        let a = CGSize(width: max(1, s.width - pad * 2), height: max(1, s.height - pad * 2))
        guard m.size.width > 0, m.size.height > 0 else { return CGRect(origin: .zero, size: s) }
        let k = min(a.width / m.size.width, a.height / m.size.height)
        let w = m.size.width * k, h = m.size.height * k
        return CGRect(x: (s.width - w) / 2, y: (s.height - h) / 2, width: w, height: h)
    }

    func displayCrop(_ vr: CGRect) -> CGRect {
        let c = m.cropRect()
        guard m.size.width > 0 else { return vr }
        let k = vr.width / m.size.width
        return CGRect(x: vr.minX + c.minX * k, y: vr.minY + c.minY * k, width: c.width * k, height: c.height * k)
    }
}

// Cadre de recadrage : filet fin et coins marqués, comme dans Photos.
struct CropFrame: View {
    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height, l: CGFloat = min(22, min(w, h) / 4)
            ZStack {
                Rectangle().strokeBorder(Color.white.opacity(0.85), lineWidth: 1)
                Path { p in
                    for (x, y, dx, dy) in [(0.0, 0.0, 1.0, 1.0), (w, 0, -1, 1), (0, h, 1, -1), (w, h, -1, -1)] {
                        p.move(to: CGPoint(x: x + dx * l, y: y + dy * 1.5)); p.addLine(to: CGPoint(x: x + dx * 1.5, y: y + dy * 1.5))
                        p.addLine(to: CGPoint(x: x + dx * 1.5, y: y + dy * l))
                    }
                }
                .stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .square))
            }
            .contentShape(Rectangle())
        }
    }
}

struct Transport: View {
    @EnvironmentObject var m: Model
    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 2) {
                Button { m.step(-1) } label: { Image(systemName: "backward.frame.fill") }.help("Image précédente (←)")
                Button { m.toggle() } label: { Image(systemName: m.playing ? "pause.fill" : "play.fill").frame(width: 18) }.help("Lecture (Espace)")
                Button { m.step(1) } label: { Image(systemName: "forward.frame.fill") }.help("Image suivante (→)")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.primary)
            .font(.system(size: 14))
            Text(m.timecode)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 78, alignment: .leading)
            Filmstrip()
                .frame(height: 46)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
    }
}

struct Filmstrip: View {
    @EnvironmentObject var m: Model
    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            let x = m.duration > 0 ? CGFloat(m.time / m.duration) * w : 0
            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    if m.filmstrip.isEmpty {
                        Rectangle().fill(Color.secondary.opacity(0.15))
                    } else {
                        ForEach(Array(m.filmstrip.enumerated()), id: \.offset) { _, img in
                            Image(decorative: img, scale: 1)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: w / CGFloat(m.filmstrip.count), height: h)
                                .clipped()
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.12)))
                RoundedRectangle(cornerRadius: 2)
                    .fill(accent)
                    .frame(width: 4, height: h + 8)
                    .shadow(color: .black.opacity(0.5), radius: 2)
                    .offset(x: min(max(0, x - 2), w - 4), y: 0)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        m.player?.pause(); m.playing = false
                        m.seek(Double(min(max(0, v.location.x / w), 1)) * m.duration)
                    }
            )
        }
    }
}

struct Inspector: View {
    @EnvironmentObject var m: Model
    var body: some View {
        Form {
            Section("Format") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                    ForEach(Ratio.allCases) { r in RatioTile(ratio: r, selected: m.ratio == r) { m.ratio = r } }
                }
                .padding(.vertical, 4)
                LabeledContent("Taille du cadre") {
                    Slider(value: $m.zoom, in: 0.4...1)
                }
                .help("Réduit le cadre pour resserrer le plan. La photo perd en résolution.")
            }
            Section("Netteté") {
                Toggle("Choisir l'image la plus nette", isOn: $m.sharpest)
                Text("Compare l'image affichée avec les deux images avant et après, et garde la plus nette.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Export") {
                Picker("Format", selection: $m.format) {
                    ForEach(OutFormat.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                LabeledContent("Taille") {
                    Text(m.outputLabel).monospacedDigit()
                }
                if m.lowRes {
                    Label("Moins de 1080 px de large : filmer en 4K pour une photo nette.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                LabeledContent("Dossier") {
                    Button(m.folder.lastPathComponent) { m.chooseFolder() }
                        .buttonStyle(.plain)
                        .foregroundStyle(accent)
                        .help(m.folder.path)
                }
            }
            if let saved = m.lastSaved {
                Section("Dernière photo") {
                    if let img = m.lastImage {
                        Image(nsImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxHeight: 180)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .frame(maxWidth: .infinity)
                            .onDrag { NSItemProvider(contentsOf: saved) ?? NSItemProvider() }
                            .help("Glisser la photo vers une autre app")
                    }
                    Text(saved.lastPathComponent).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    HStack {
                        Button("Afficher") { NSWorkspace.shared.activateFileViewerSelecting([saved]) }
                        Button("Copier") { m.copyLast() }.help("Copier la photo (⇧⌘C)")
                        Spacer()
                        ShareLink(item: saved) { Label("Partager", systemImage: "square.and.arrow.up") }
                    }
                }
            }
            if let msg = m.message {
                Section { Text(msg).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
    }
}

struct RatioTile: View {
    let ratio: Ratio
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                let v = ratio.value ?? 1.5
                let bw: CGFloat = v >= 1 ? 26 : 26 * v, bh: CGFloat = v >= 1 ? 26 / v : 26
                RoundedRectangle(cornerRadius: 2.5)
                    .strokeBorder(selected ? accent : Color.secondary, style: StrokeStyle(lineWidth: 1.5, dash: ratio == .original ? [3, 2] : []))
                    .frame(width: bw, height: bh)
                    .frame(height: 30)
                Text(ratio.label).font(.caption2.weight(.medium))
                Text(ratio == .original ? "vidéo" : ratio.rawValue).font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(selected ? accent.opacity(0.14) : Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? accent : Color.clear, lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
