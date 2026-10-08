// cartes.swift — caméra, OCR (Vision) et écriture dans Contacts.
//
// Sous-commandes :
//   cameras                                     liste les caméras
//   scan --out DOSSIER [--camera NOM] [--source TEXTE]
//   images --out DOSSIER [--source TEXTE] PHOTO...   photos déjà prises
//   contacts ENTREE.json SORTIE.json [--groupe NOM]
//
// Compilé par le script `cartes` (swiftc -swift-version 5).

import AppKit
import AVFoundation
import Contacts
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import Vision

// MARK: - Outils

func argValue(_ name: String, _ args: [String]) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func fail(_ msg: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(code)
}

/// Préfixe unique des cartes d'un lancement : horodatage + 8 caractères aléatoires.
func nouveauLot() -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyyMMdd-HHmmss"
    return f.string(from: Date()) + "-" + String(format: "%08x", UInt32.random(in: 0...UInt32.max))
}

func fold(_ s: String) -> String {
    s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
}

// MARK: - Caméras

func allCameras() -> [AVCaptureDevice] {
    var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .deskViewCamera]
    if #available(macOS 14.0, *) {
        types += [.external, .continuityCamera]
    } else {
        types += [.externalUnknown]
    }
    return AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified).devices
}

func pickCamera(_ wanted: String?) -> AVCaptureDevice {
    let cams = allCameras()
    if cams.isEmpty { fail("Aucune caméra trouvée.") }
    if let wanted, !wanted.isEmpty {
        if let c = cams.first(where: { fold($0.localizedName).contains(fold(wanted)) }) { return c }
        fail("Aucune caméra ne contient « \(wanted) ». Caméras : " + cams.map(\.localizedName).joined(separator: ", "))
    }
    // Par défaut : une webcam USB plutôt que l'iPhone, qui peut se déconnecter.
    if #available(macOS 14.0, *) {
        if let c = cams.first(where: { $0.deviceType == .external }) { return c }
    }
    return cams[0]
}

// MARK: - Données d'une carte

struct Ligne: Codable {
    var texte: String
    var confiance: Float
    var x: Double, y: Double, l: Double, h: Double  // coordonnées normalisées, origine en haut à gauche
}

struct Adresse: Codable {
    var rue: String?, codePostal: String?, ville: String?, pays: String?
}

struct Detecte: Codable {
    var telephones: [String] = []
    var emails: [String] = []
    var sites: [String] = []
    var adresses: [Adresse] = []
}

struct Carte: Codable {
    var id: String
    var source: String
    var scanneeLe: String
    var image: String
    var lignes: [Ligne]
    var qr: [String]
    var detecte: Detecte
}

// MARK: - OCR

struct Lecture {
    var lignes: [Ligne]
    var tokens: Set<String>
    var caracteres: Int
    var qualite: Float  // caractères × confiance moyenne : sert à garder la meilleure image
}

func lire(_ image: CGImage) -> Lecture {
    let req = VNRecognizeTextRequest()
    req.recognitionLevel = .accurate
    req.recognitionLanguages = ["fr-FR", "en-US"]
    // La correction linguistique « corrige » les noms propres et les e-mails : on la coupe.
    req.usesLanguageCorrection = false
    req.minimumTextHeight = 0.008
    try? VNImageRequestHandler(cgImage: image).perform([req])

    var lignes: [Ligne] = []
    for obs in req.results ?? [] {
        guard let best = obs.topCandidates(1).first else { continue }
        let t = best.string.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { continue }
        let b = obs.boundingBox
        lignes.append(Ligne(texte: t, confiance: best.confidence,
                            x: b.minX, y: 1 - b.maxY, l: b.width, h: b.height))
    }
    lignes.sort { abs($0.y - $1.y) > 0.01 ? $0.y < $1.y : $0.x < $1.x }

    var tokens = Set<String>()
    var caracteres = 0
    var conf: Float = 0
    for l in lignes {
        caracteres += l.texte.count
        conf += l.confiance
        for mot in fold(l.texte).split(whereSeparator: { !$0.isLetter && !$0.isNumber }) where mot.count >= 2 {
            tokens.insert(String(mot))
        }
    }
    let moy = lignes.isEmpty ? 0 : conf / Float(lignes.count)
    return Lecture(lignes: lignes, tokens: tokens, caracteres: caracteres, qualite: Float(caracteres) * moy)
}

func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
    let u = a.union(b).count
    return u == 0 ? 0 : Double(a.intersection(b).count) / Double(u)
}

/// Part de `a` qu'on retrouve dans `b`.
func inclusion(_ a: Set<String>, dans b: Set<String>) -> Double {
    a.isEmpty ? 0 : Double(a.intersection(b).count) / Double(a.count)
}

func detecter(_ texte: String) -> Detecte {
    var d = Detecte()
    let types: NSTextCheckingResult.CheckingType = [.phoneNumber, .link, .address]
    guard let det = try? NSDataDetector(types: types.rawValue) else { return d }
    let ns = texte as NSString
    for m in det.matches(in: texte, range: NSRange(location: 0, length: ns.length)) {
        switch m.resultType {
        case .phoneNumber:
            if let p = m.phoneNumber { d.telephones.append(p) }
        case .link:
            guard let url = m.url else { continue }
            if url.scheme == "mailto" {
                d.emails.append(String(url.absoluteString.dropFirst("mailto:".count)))
            } else {
                d.sites.append(ns.substring(with: m.range))
            }
        case .address:
            let c = m.addressComponents ?? [:]
            d.adresses.append(Adresse(rue: c[.street], codePostal: c[.zip], ville: c[.city], pays: c[.country]))
        default: break
        }
    }
    return d
}

func qrCodes(_ image: CGImage) -> [String] {
    let req = VNDetectBarcodesRequest()
    try? VNImageRequestHandler(cgImage: image).perform([req])
    return (req.results ?? []).compactMap(\.payloadStringValue)
}

// MARK: - Recadrage

/// Redresse la carte si on trouve son contour, sinon recadre autour du texte.
func recadrer(_ image: CGImage, lignes: [Ligne], ctx: CIContext) -> CGImage {
    let ci = CIImage(cgImage: image)
    let W = CGFloat(image.width), H = CGFloat(image.height)

    let req = VNDetectRectanglesRequest()
    req.minimumAspectRatio = 0.45
    req.maximumAspectRatio = 0.95
    req.minimumSize = 0.15
    req.quadratureTolerance = 25
    req.maximumObservations = 3
    try? VNImageRequestHandler(cgImage: image).perform([req])

    // Le contour retenu doit contenir l'essentiel du texte.
    let centres = lignes.map { CGPoint(x: $0.x + $0.l / 2, y: 1 - ($0.y + $0.h / 2)) }
    for r in req.results ?? [] {
        let dedans = centres.filter { r.boundingBox.insetBy(dx: -0.01, dy: -0.01).contains($0) }.count
        guard !centres.isEmpty, Double(dedans) / Double(centres.count) >= 0.7 else { continue }
        func p(_ v: CGPoint) -> CIVector { CIVector(x: v.x * W, y: v.y * H) }
        let f = CIFilter(name: "CIPerspectiveCorrection")!
        f.setValue(ci, forKey: kCIInputImageKey)
        f.setValue(p(r.topLeft), forKey: "inputTopLeft")
        f.setValue(p(r.topRight), forKey: "inputTopRight")
        f.setValue(p(r.bottomLeft), forKey: "inputBottomLeft")
        f.setValue(p(r.bottomRight), forKey: "inputBottomRight")
        if let out = f.outputImage, let cg = ctx.createCGImage(out, from: out.extent) { return cg }
    }

    guard !lignes.isEmpty else { return image }
    var minX = 1.0, minY = 1.0, maxX = 0.0, maxY = 0.0
    for l in lignes {
        minX = min(minX, l.x); minY = min(minY, l.y)
        maxX = max(maxX, l.x + l.l); maxY = max(maxY, l.y + l.h)
    }
    let marge = 0.06
    let rect = CGRect(x: max(0, minX - marge) * W, y: max(0, minY - marge) * H,
                      width: (min(1, maxX + marge) - max(0, minX - marge)) * W,
                      height: (min(1, maxY + marge) - max(0, minY - marge)) * H)
    return image.cropping(to: rect.integral) ?? image
}

func ecrireJPEG(_ image: CGImage, _ url: URL) -> Bool {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return false }
    CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
    return CGImageDestinationFinalize(dest)
}

/// Écrit `ID.jpg` (carte recadrée) et `ID.json` (texte lu, QR codes, numéros et e-mails détectés).
/// Renvoie false si l'une des deux écritures échoue ou si la carte existe déjà.
func enregistrerCarte(_ lecture: Lecture, image: CGImage, id: String, source: String, outDir: URL, ctx: CIContext) -> Bool {
    let jpg = outDir.appendingPathComponent("\(id).jpg"), json = outDir.appendingPathComponent("\(id).json")
    if FileManager.default.fileExists(atPath: json.path) || FileManager.default.fileExists(atPath: jpg.path) {
        FileHandle.standardError.write("La carte \(id) existe déjà : rien n'est écrasé.\n".data(using: .utf8)!)
        return false
    }
    let recadree = recadrer(image, lignes: lecture.lignes, ctx: ctx)
    // Si le recadrage donne une image inutilisable, on garde la photo entière.
    guard ecrireJPEG(recadree, jpg) || ecrireJPEG(image, jpg) else {
        FileHandle.standardError.write("Photo impossible à écrire pour \(id).\n".data(using: .utf8)!)
        return false
    }
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime]
    iso.timeZone = .current
    let carte = Carte(id: id, source: source, scanneeLe: iso.string(from: Date()), image: "\(id).jpg",
                      lignes: lecture.lignes, qr: qrCodes(image),
                      detecte: detecter(lecture.lignes.map(\.texte).joined(separator: "\n")))
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    do {
        try enc.encode(carte).write(to: json, options: .atomic)
        return true
    } catch {
        FileHandle.standardError.write("Écriture impossible pour \(id) : \(error)\n".data(using: .utf8)!)
        try? FileManager.default.removeItem(at: jpg)
        return false
    }
}

// MARK: - Scan

final class Scanner: NSObject, NSApplicationDelegate, AVCaptureVideoDataOutputSampleBufferDelegate {
    let outDir: URL
    let source: String
    let device: AVCaptureDevice
    let session = AVCaptureSession()
    let queue = DispatchQueue(label: "cartes.video")
    let ctx = CIContext()

    var window: NSWindow!
    var preview: AVCaptureVideoPreviewLayer!
    var statut: NSTextField!
    var compteur: NSTextField!

    // État, lu et écrit seulement sur `queue`.
    var prochaineAnalyse = Date.distantPast
    var vignettePrecedente: [UInt8]?
    var candidat: (lecture: Lecture, image: CGImage)?
    var confirmations = 0
    var derniere: (id: String, lecture: Lecture)?
    var forcer = false
    var retireeDepuisCapture = false  // on a vu bouger la scène ou disparaître le texte depuis la dernière capture
    var nombre = 0
    var ids: [String] = []
    let lot: String

    init(outDir: URL, source: String, device: AVCaptureDevice) {
        self.outDir = outDir
        self.source = source
        self.device = device
        lot = nouveauLot()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        construireFenetre()
        AVCaptureDevice.requestAccess(for: .video) { ok in
            DispatchQueue.main.async {
                guard ok else {
                    fail("Accès à la caméra refusé. Autorise ton terminal dans Réglages Système > Confidentialité > Caméra.", code: 2)
                }
                self.demarrerCamera()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        session.stopRunning()
        queue.sync {
            print("\(nombre) carte(s) enregistrée(s) dans \(outDir.path)")
        }
    }

    func construireFenetre() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 680),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "Cartes de visite — \(device.localizedName)"
        let vue = NSView()
        vue.wantsLayer = true
        vue.layer?.backgroundColor = NSColor.black.cgColor
        window.contentView = vue

        preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspect
        preview.frame = vue.bounds
        preview.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        preview.borderColor = NSColor.systemGreen.cgColor
        vue.layer?.addSublayer(preview)

        statut = etiquette(taille: 26, gras: true)
        compteur = etiquette(taille: 15, gras: false)
        compteur.stringValue = "Échap : terminer · Espace : forcer la capture · ⌫ : annuler la dernière carte"
        for (v, bas) in [(statut!, 44.0), (compteur!, 14.0)] {
            vue.addSubview(v)
            v.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                v.centerXAnchor.constraint(equalTo: vue.centerXAnchor),
                v.bottomAnchor.constraint(equalTo: vue.bottomAnchor, constant: -bas),
                v.widthAnchor.constraint(lessThanOrEqualTo: vue.widthAnchor, constant: -32),
            ])
        }
        afficher("Démarrage de la caméra…")

        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            switch e.keyCode {
            case 53, 12: NSApp.terminate(nil)                           // Échap, q
            case 49: self.queue.async { self.forcer = true }            // Espace
            case 51: self.queue.async { self.annulerDerniere() }        // ⌫
            default: return e
            }
            return nil
        }

        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func etiquette(taille: CGFloat, gras: Bool) -> NSTextField {
        let t = NSTextField(labelWithString: "")
        t.font = gras ? .boldSystemFont(ofSize: taille) : .systemFont(ofSize: taille)
        t.textColor = .white
        t.alignment = .center
        t.wantsLayer = true
        t.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        t.layer?.cornerRadius = 6
        return t
    }

    func afficher(_ texte: String) {
        DispatchQueue.main.async { self.statut.stringValue = "  \(texte)  " }
    }

    func flash() {
        DispatchQueue.main.async {
            NSSound(named: "Glass")?.play()
            self.preview.borderWidth = 12
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.preview.borderWidth = 0 }
        }
    }

    func demarrerCamera() {
        do {
            let input = try AVCaptureDeviceInput(device: device)
            session.beginConfiguration()
            session.sessionPreset = .high
            if session.canAddInput(input) { session.addInput(input) }
            // Prend la meilleure définition disponible à 15 i/s ou plus.
            let formats = device.formats.filter { f in f.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 15 } }
            if let best = formats.max(by: {
                let a = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
                let b = CMVideoFormatDescriptionGetDimensions($1.formatDescription)
                return Int(a.width) * Int(a.height) < Int(b.width) * Int(b.height)
            }), (try? device.lockForConfiguration()) != nil {
                device.activeFormat = best
                device.unlockForConfiguration()
            }
            let output = AVCaptureVideoDataOutput()
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: queue)
            if session.canAddOutput(output) { session.addOutput(output) }
            session.commitConfiguration()
        } catch {
            fail("Impossible d'ouvrir la caméra : \(error.localizedDescription)")
        }
        if let c = preview.connection, c.isVideoMirroringSupported {
            c.automaticallyAdjustsVideoMirroring = false
            c.isVideoMirrored = false
        }
        queue.async { self.session.startRunning() }
        let d = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        print("Caméra : \(device.localizedName) (\(d.width)×\(d.height))")
        afficher("Posez ou présentez une carte")
    }

    // Vignette 64×48 en niveaux de gris, pour mesurer le mouvement.
    func vignette(_ image: CIImage) -> [UInt8] {
        let w = 64, h = 48
        let f = CIFilter(name: "CILanczosScaleTransform")!
        let sy = CGFloat(h) / image.extent.height, sx = CGFloat(w) / image.extent.width
        f.setValue(image, forKey: kCIInputImageKey)
        f.setValue(sy, forKey: kCIInputScaleKey)
        f.setValue(sx / sy, forKey: kCIInputAspectRatioKey)
        var buf = [UInt8](repeating: 0, count: w * h)
        if let out = f.outputImage {
            ctx.render(out, toBitmap: &buf, rowBytes: w, bounds: CGRect(x: 0, y: 0, width: w, height: h),
                       format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())
        }
        return buf
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let maintenant = Date()
        guard maintenant >= prochaineAnalyse, let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        prochaineAnalyse = maintenant.addingTimeInterval(0.25)

        let ci = CIImage(cvPixelBuffer: pb)
        let v = vignette(ci)
        var mouvement = 0.0
        if let p = vignettePrecedente {
            mouvement = Double(zip(v, p).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }) / Double(v.count)
        }
        vignettePrecedente = v
        if mouvement > 14 {  // la carte bouge : image floue, on attend
            candidat = nil
            confirmations = 0
            forcer = false
            retireeDepuisCapture = true
            return
        }

        guard let cg = ctx.createCGImage(ci, from: ci.extent) else { return }
        let lecture = lire(cg)
        analyser(lecture, image: cg)
    }

    func analyser(_ lecture: Lecture, image: CGImage) {
        guard lecture.lignes.count >= 2, lecture.caracteres >= 12 else {
            candidat = nil
            confirmations = 0
            forcer = false
            retireeDepuisCapture = true
            if derniere == nil || nombre == 0 { afficher("Posez ou présentez une carte") }
            else { afficher("✓ \(nombre) carte(s). Carte suivante…") }
            return
        }

        // Il faut lire deux fois de suite le même texte avant de capturer.
        if let c = candidat, jaccard(c.lecture.tokens, lecture.tokens) >= 0.6 {
            confirmations += 1
            if lecture.qualite > c.lecture.qualite { candidat = (lecture, image) }
        } else {
            candidat = (lecture, image)
            confirmations = 1
        }
        guard confirmations >= 2 || forcer, let c = candidat else { return }

        if let d = derniere, !forcer {
            // Sans retrait observé, un texte proche (ou une vue partielle) est la carte déjà enregistrée.
            // Après un retrait, il faut un texte presque identique : deux collègues de la même société
            // partagent logo, adresse et standard, et l'OCR peut ne lire que ces parties communes.
            let meme = retireeDepuisCapture
                ? jaccard(c.lecture.tokens, d.lecture.tokens) >= 0.85
                : jaccard(c.lecture.tokens, d.lecture.tokens) >= 0.6
                    || inclusion(c.lecture.tokens, dans: d.lecture.tokens) >= 0.85
            if meme {
                afficher("✓ Carte \(nombre) enregistrée. Carte suivante…")
                return
            }
            // Dans le doute, on capture : Claude fusionne ensuite deux photos de la même carte.
            // On n'écrase jamais une carte déjà enregistrée.
        }

        forcer = false
        candidat = nil
        confirmations = 0
        let id = String(format: "%@-%03d", lot, nombre + 1)
        guard enregistrerCarte(c.lecture, image: c.image, id: id, source: source, outDir: outDir, ctx: ctx) else {
            DispatchQueue.main.async { NSSound(named: "Basso")?.play() }
            afficher("⚠︎ Carte non enregistrée (voir le terminal). Représentez-la")
            return
        }
        nombre += 1
        ids.append(id)
        derniere = (id, c.lecture)
        retireeDepuisCapture = false
        flash()
        afficher("✓ Carte \(nombre) enregistrée")
    }

    func annulerDerniere() {
        guard let id = ids.popLast() else { return }
        for ext in ["jpg", "json"] {
            try? FileManager.default.removeItem(at: outDir.appendingPathComponent("\(id).\(ext)"))
        }
        nombre -= 1
        derniere = nil
        retireeDepuisCapture = false
        candidat = nil
        confirmations = 0
        DispatchQueue.main.async { NSSound(named: "Funk")?.play() }
        afficher("Carte \(nombre + 1) annulée : représentez-la")
    }
}

func scan(_ args: [String]) {
    guard let out = argValue("--out", args) else { fail("Usage : cartes-outil scan --out DOSSIER [--camera NOM] [--source TEXTE]") }
    let outDir = URL(fileURLWithPath: out, isDirectory: true)
    try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    let scanner = Scanner(outDir: outDir, source: argValue("--source", args) ?? "",
                          device: pickCamera(argValue("--camera", args)))
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    app.delegate = scanner
    app.run()
}

/// Traite des photos déjà prises (une carte par photo), par exemple depuis l'iPhone.
func images(_ args: [String]) {
    guard let out = argValue("--out", args) else { fail("Usage : cartes-outil images --out DOSSIER [--source TEXTE] PHOTO...") }
    let source = argValue("--source", args) ?? ""
    let outDir = URL(fileURLWithPath: out, isDirectory: true)
    try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    let options = Set(["--out", out, "--source", source])
    let fichiers = args.filter { !options.contains($0) }
    let lot = nouveauLot()
    let ctx = CIContext()
    var n = 0
    for chemin in fichiers {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: chemin) as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldAllowFloat: false] as CFDictionary) else {
            print("Illisible : \(chemin)"); continue
        }
        let lecture = lire(img)
        guard lecture.lignes.count >= 2 else { print("Pas de texte : \(chemin)"); continue }
        if enregistrerCarte(lecture, image: img, id: String(format: "%@-p%03d", lot, n + 1), source: source, outDir: outDir, ctx: ctx) {
            n += 1
        }
    }
    print("\(n) carte(s) enregistrée(s) dans \(outDir.path)")
}

// MARK: - Contacts

struct Telephone: Codable { var numero: String; var type: String }
struct Personne: Codable {
    var cle: String
    var prenom: String, nom: String, societe: String, poste: String
    var telephones: [Telephone]
    var emails: [String]
    var site: String, linkedin: String
    var rue: String, codePostal: String, ville: String, pays: String
}
struct Resultat: Codable { var cle: String; var statut: String; var identifiant: String; var detail: String }

/// Adresses partagées par toute une société : elles ne prouvent pas qu'il s'agit de la même personne.
let emailsGeneriques: Set<String> = ["contact", "info", "infos", "accueil", "hello", "bonjour", "commercial", "sales",
                                     "admin", "office", "direction", "secretariat", "rh", "recrutement", "support",
                                     "service", "serviceclient", "communication", "marketing", "devis", "agence", "team"]

func emailPersonnel(_ e: String) -> Bool {
    let local = fold(e.split(separator: "@").first.map(String.init) ?? "").filter { $0.isLetter || $0.isNumber }
    return !emailsGeneriques.contains(local)
}

/// Cherche une fiche existante pour la même personne. On compare l'e-mail personnel, le mobile
/// (un fixe est souvent le standard), puis prénom + nom avec la société quand les deux en ont une.
func existant(_ p: Personne, store: CNContactStore) -> (contact: CNContact, ambigu: Bool)? {
    let keys = [CNContactIdentifierKey, CNContactGivenNameKey, CNContactFamilyNameKey,
                CNContactOrganizationNameKey] as [CNKeyDescriptor]
    let nomCarte = fold(p.prenom + " " + p.nom).trimmingCharacters(in: .whitespaces)
    func nom(_ c: CNContact) -> String { fold(c.givenName + " " + c.familyName).trimmingCharacters(in: .whitespaces) }
    // Même e-mail personnel ou même mobile : la même personne si les noms concordent (ou sont tous deux absents).
    // Sinon (mobile réattribué, fiche sans nom), c'est ambigu : on ne crée rien et on le signale.
    var parCoordonnees: [CNContact] = []
    for e in p.emails where emailPersonnel(e) {
        parCoordonnees += (try? store.unifiedContacts(matching: CNContact.predicateForContacts(matchingEmailAddress: e), keysToFetch: keys)) ?? []
    }
    for t in p.telephones where t.type == "mobile" {
        let pred = CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: t.numero))
        parCoordonnees += (try? store.unifiedContacts(matching: pred, keysToFetch: keys)) ?? []
    }
    if let c = parCoordonnees.first(where: { nom($0) == nomCarte }) { return (c, false) }
    if let c = parCoordonnees.first { return (c, true) }
    if !p.nom.isEmpty, !p.prenom.isEmpty {
        let pred = CNContact.predicateForContacts(matchingName: "\(p.prenom) \(p.nom)")
        let cs = (try? store.unifiedContacts(matching: pred, keysToFetch: keys)) ?? []
        if let c = cs.first(where: {
            fold($0.givenName) == fold(p.prenom) && fold($0.familyName) == fold(p.nom)
                && ($0.organizationName.isEmpty || p.societe.isEmpty || fold($0.organizationName) == fold(p.societe))
        }) { return (c, false) }
    }
    // Carte de société sans nom de personne : une fiche société du même nom existe-t-elle déjà ?
    if p.prenom.isEmpty, p.nom.isEmpty, !p.societe.isEmpty {
        var trouve: CNContact?
        let req = CNContactFetchRequest(keysToFetch: keys)
        try? store.enumerateContacts(with: req) { c, stop in
            if c.givenName.isEmpty, c.familyName.isEmpty, fold(c.organizationName) == fold(p.societe) {
                trouve = c
                stop.pointee = true
            }
        }
        if let c = trouve { return (c, false) }
    }
    return nil
}

func contacts(_ args: [String]) {
    guard args.count >= 2 else { fail("Usage : cartes-outil contacts ENTREE.json SORTIE.json [--groupe NOM]") }
    let nomGroupe = argValue("--groupe", args) ?? "Cartes de visite"
    guard let data = FileManager.default.contents(atPath: args[0]),
          let personnes = try? JSONDecoder().decode([Personne].self, from: data) else { fail("Lecture impossible : \(args[0])") }

    let store = CNContactStore()
    let sem = DispatchSemaphore(value: 0)
    var autorise = false
    store.requestAccess(for: .contacts) { ok, _ in autorise = ok; sem.signal() }
    sem.wait()
    guard autorise else {
        fail("Accès aux Contacts refusé. Autorise ton terminal dans Réglages Système > Confidentialité > Contacts.", code: 2)
    }

    var groupe = (try? store.groups(matching: nil))?.first { $0.name == nomGroupe }
    if groupe == nil {
        let g = CNMutableGroup()
        g.name = nomGroupe
        let req = CNSaveRequest()
        req.add(g, toContainerWithIdentifier: nil)
        do { try store.execute(req); groupe = g } catch { fail("Création du groupe « \(nomGroupe) » impossible : \(error)") }
    }

    var resultats: [Resultat] = []
    for p in personnes {
        if let (c, ambigu) = existant(p, store: store) {
            let qui = "\(c.givenName) \(c.familyName) \(c.organizationName)".trimmingCharacters(in: .whitespaces)
            resultats.append(Resultat(cle: p.cle, statut: ambigu ? "ambigu" : "existant", identifiant: c.identifier,
                                      detail: ambigu ? "même e-mail ou mobile que la fiche « \(qui) »" : qui))
            continue
        }
        let c = CNMutableContact()
        c.givenName = p.prenom
        c.familyName = p.nom
        c.organizationName = p.societe
        c.jobTitle = p.poste
        c.contactType = (p.prenom + p.nom).isEmpty ? .organization : .person
        c.phoneNumbers = p.telephones.map { t in
            let label = t.type == "mobile" ? CNLabelPhoneNumberMobile
                : t.type == "fax" ? CNLabelPhoneNumberWorkFax : CNLabelWork
            return CNLabeledValue(label: label, value: CNPhoneNumber(stringValue: t.numero))
        }
        c.emailAddresses = p.emails.map { CNLabeledValue(label: CNLabelWork, value: $0 as NSString) }
        if !p.site.isEmpty { c.urlAddresses = [CNLabeledValue(label: CNLabelWork, value: p.site as NSString)] }
        if !p.linkedin.isEmpty {
            let profil = CNSocialProfile(urlString: p.linkedin, username: nil, userIdentifier: nil, service: CNSocialProfileServiceLinkedIn)
            c.socialProfiles = [CNLabeledValue(label: CNLabelWork, value: profil)]
        }
        if !(p.rue + p.codePostal + p.ville).isEmpty {
            let a = CNMutablePostalAddress()
            a.street = p.rue
            a.postalCode = p.codePostal
            a.city = p.ville
            a.country = p.pays
            c.postalAddresses = [CNLabeledValue(label: CNLabelWork, value: a)]
        }
        let req = CNSaveRequest()
        req.add(c, toContainerWithIdentifier: nil)
        if let g = groupe { req.addMember(c, to: g) }
        do {
            try store.execute(req)
            resultats.append(Resultat(cle: p.cle, statut: "cree", identifiant: c.identifier, detail: ""))
            continue
        } catch {
            if groupe == nil {
                resultats.append(Resultat(cle: p.cle, statut: "erreur", identifiant: "", detail: "\(error.localizedDescription)"))
                continue
            }
        }
        // Certains comptes (Google, Exchange) refusent les groupes : on crée la fiche sans groupe.
        let seul = CNSaveRequest()
        seul.add(c, toContainerWithIdentifier: nil)
        do {
            try store.execute(seul)
            resultats.append(Resultat(cle: p.cle, statut: "cree", identifiant: c.identifier, detail: "créé hors groupe"))
        } catch {
            resultats.append(Resultat(cle: p.cle, statut: "erreur", identifiant: "", detail: "\(error.localizedDescription)"))
        }
    }

    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted]
    do { try enc.encode(resultats).write(to: URL(fileURLWithPath: args[1])) } catch { fail("Écriture impossible : \(args[1])") }
}

// MARK: - Point d'entrée

var args = Array(CommandLine.arguments.dropFirst())
let commande = args.isEmpty ? "" : args.removeFirst()
switch commande {
case "cameras":
    for c in allCameras() { print(c.localizedName) }
case "scan":
    scan(args)
case "images":
    images(args)
case "contacts":
    contacts(args)
default:
    fail("Usage : cartes-outil cameras | scan --out DOSSIER [--camera NOM] [--source TEXTE] | images --out DOSSIER [--source TEXTE] PHOTO... | contacts ENTREE.json SORTIE.json [--groupe NOM]")
}
