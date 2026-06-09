import SwiftUI
import AVFoundation

// MARK: - Models

enum PracticeType: String, CaseIterable, Codable {
    case attack  = "攻撃"
    case defense = "防御"
}

enum DrillMode: String, CaseIterable, Codable {
    case hpBar  = "HPバー確認"
    case effect = "エフェクト確認"
    case sound  = "音確認"
    case impact = "インパクト確認"

    static func available(for type: PracticeType) -> [DrillMode] {
        type == .attack ? DrillMode.allCases : [.hpBar, .effect, .sound]
    }
}

enum ResponsePractice: String, CaseIterable, Codable {
    case both      = "両方"
    case pressOnly = "押す"
    case holdOnly  = "押さない"
}

enum CueType { case hit, guard_, impact, neutral }
enum ResponseAction { case press, timeout }

enum DrillPhase {
    case idle           // 攻撃: 攻撃ボタン待ち
    case passiveReady   // 防御: 次へボタン待ち
    case startup        // ランダム待機 or 発生フレーム待ち
    case cueActive      // 判定窓オープン
    case feedback(Bool) // 正誤表示（手動で次へ進む）
}

struct DrillSettings: Codable {
    var practiceType: PracticeType = .attack
    var mode: DrillMode = .hpBar
    var responsePractice: ResponsePractice = .both
    var confirmFrames: Int = 18
    var startupFrames: Int = 8

    var confirmSeconds: Double { Double(confirmFrames) / 60.0 }
    var startupSeconds: Double { Double(startupFrames) / 60.0 }

    private static let key = "fhc_settings_v2"
    static func load() -> DrillSettings {
        guard let d = UserDefaults.standard.data(forKey: key),
              let s = try? JSONDecoder().decode(DrillSettings.self, from: d) else { return .init() }
        return s
    }
    func save() {
        if let d = try? JSONEncoder().encode(self) { UserDefaults.standard.set(d, forKey: Self.key) }
    }
}

struct SessionRecord: Codable, Identifiable {
    var id = UUID()
    var date = Date()
    var mode: DrillMode
    var practiceType: PracticeType
    var successRate: Double
    var avgReactionFrames: Double
    var bestStreak: Int
    var totalAttempts: Int
}

// MARK: - TonePlayer

class TonePlayer {
    static let shared = TonePlayer()
    private var players: [AVAudioPlayer] = []

    init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    func playHit()   { play(hz: 880, duration: 0.08) }
    func playGuard() { play(hz: 200, duration: 0.12) }

    private func play(hz: Double, duration: TimeInterval) {
        guard let player = makeTone(hz: hz, duration: duration) else { return }
        players.removeAll { !$0.isPlaying }
        players.append(player)
        player.play()
    }

    private func makeTone(hz: Double, duration: TimeInterval) -> AVAudioPlayer? {
        let sampleRate = 44100
        let numSamples = Int(Double(sampleRate) * duration)
        var wav = Data()
        func le<T: FixedWidthInteger>(_ v: T) {
            var val = v.littleEndian
            wav.append(contentsOf: withUnsafeBytes(of: &val) { Array($0) })
        }
        let dataSize = numSamples * 2
        wav.append(contentsOf: "RIFF".utf8); le(Int32(36 + dataSize))
        wav.append(contentsOf: "WAVE".utf8); wav.append(contentsOf: "fmt ".utf8)
        le(Int32(16)); le(Int16(1)); le(Int16(1))
        le(Int32(sampleRate)); le(Int32(sampleRate * 2)); le(Int16(2)); le(Int16(16))
        wav.append(contentsOf: "data".utf8); le(Int32(dataSize))
        for i in 0..<numSamples {
            let t = Double(i) / Double(sampleRate)
            let fade = min(Double(i), Double(numSamples - i)) / max(Double(sampleRate) * 0.015, 1)
            let s = Int16(sin(2.0 * .pi * hz * t) * 12000.0 * min(fade, 1.0))
            le(s)
        }
        return try? AVAudioPlayer(data: wav)
    }
}

// MARK: - Store

class RecordsStore: ObservableObject {
    @Published var records: [SessionRecord] = []
    private let key = "fhc_records_v2"
    init() { load() }
    func append(_ r: SessionRecord) { records.insert(r, at: 0); persist() }
    private func load() {
        guard let d = UserDefaults.standard.data(forKey: key),
              let v = try? JSONDecoder().decode([SessionRecord].self, from: d) else { return }
        records = v
    }
    private func persist() {
        if let d = try? JSONEncoder().encode(records) { UserDefaults.standard.set(d, forKey: key) }
    }
}

// MARK: - Root

struct ContentView: View {
    @StateObject private var store = RecordsStore()
    var body: some View {
        NavigationStack { StartView().environmentObject(store) }
    }
}

// MARK: - Start View

struct StartView: View {
    @EnvironmentObject var store: RecordsStore
    @State private var settings = DrillSettings.load()
    @State private var toPractice = false
    @State private var showRecords = false

    var body: some View {
        Form {
            Section("練習タイプ") {
                Picker("タイプ", selection: $settings.practiceType) {
                    ForEach(PracticeType.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: settings.practiceType) { _ in
                    let available = DrillMode.available(for: settings.practiceType)
                    if !available.contains(settings.mode) { settings.mode = available[0] }
                }
            }

            Section("モード") {
                Picker("モード", selection: $settings.mode) {
                    ForEach(DrillMode.available(for: settings.practiceType), id: \.self) {
                        Text($0.rawValue).tag($0)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }

            Section("応答練習") {
                Picker("応答練習", selection: $settings.responsePractice) {
                    ForEach(ResponsePractice.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Section("判定窓") {
                Stepper(value: $settings.confirmFrames, in: 4...60) {
                    HStack {
                        Text("\(settings.confirmFrames) F").monospacedDigit().bold()
                        Text("≈ \(Int(settings.confirmSeconds * 1000)) ms")
                            .foregroundColor(.secondary).font(.footnote)
                    }
                }
            }

            if settings.practiceType == .attack {
                Section("発生フレーム") {
                    Stepper(value: $settings.startupFrames, in: 1...60) {
                        HStack {
                            Text("\(settings.startupFrames) F").monospacedDigit().bold()
                            Text("≈ \(Int(settings.startupSeconds * 1000)) ms")
                                .foregroundColor(.secondary).font(.footnote)
                        }
                    }
                }
            }

            Section {
                Button {
                    settings.save(); toPractice = true
                } label: {
                    HStack { Spacer(); Text("練習開始").font(.headline); Spacer() }
                }
            }
        }
        .navigationTitle("Hit Confirm")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) { Button("記録") { showRecords = true } }
        }
        .navigationDestination(isPresented: $toPractice) {
            PracticeView(settings: settings).environmentObject(store)
        }
        .sheet(isPresented: $showRecords) {
            RecordsView().environmentObject(store)
        }
    }
}

// MARK: - Practice View

struct PracticeView: View {
    let settings: DrillSettings
    @EnvironmentObject var store: RecordsStore
    @Environment(\.dismiss) var dismiss

    @State private var confirmFrames: Int = 18
    @State private var startupFrames: Int = 8
    @State private var responsePractice: ResponsePractice = .both
    @State private var phase: DrillPhase = .idle
    @State private var currentCue: CueType = .neutral
    @State private var cueStartTime = Date()
    @State private var generation = 0

    @State private var total = 0
    @State private var successes = 0
    @State private var streak = 0
    @State private var best = 0
    @State private var reactionFrames: [Double] = []

    @State private var hp: Double = 0.7
    @State private var damageFlash: Double = 0.0

    @State private var resultRecord: SessionRecord? = nil
    @State private var goHomeAfterResult = false

    var mode: DrillMode { settings.mode }
    var practiceType: PracticeType { settings.practiceType }
    var confirmSec: Double { Double(confirmFrames) / 60.0 }
    var startupSec: Double { Double(startupFrames) / 60.0 }

    var isCueActive: Bool  { if case .cueActive    = phase { return true }; return false }
    var isIdle: Bool       { if case .idle          = phase { return true }; return false }
    var isPassiveReady: Bool { if case .passiveReady = phase { return true }; return false }
    var isFeedback: Bool   { if case .feedback(_)   = phase { return true }; return false }
    var feedbackOk: Bool? {
        if case .feedback(let ok) = phase { return ok }; return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            inlineSettings.padding(.horizontal).padding(.top, 8)
            hpBar.padding(.horizontal).padding(.top, 12)
            cueArea.padding(.horizontal).padding(.top, 12)
            statsBar.padding(.horizontal).padding(.top, 12)
            Spacer()
            actionArea.padding(.horizontal).padding(.bottom, 32)
        }
        .navigationTitle("練習中")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("終了") { endSession() }.tint(.red)
            }
        }
        .fullScreenCover(item: $resultRecord, onDismiss: {
            if goHomeAfterResult { dismiss() } else { resetSession() }
        }) { rec in
            ResultView(record: rec) {
                goHomeAfterResult = false; resultRecord = nil
            } onHome: {
                goHomeAfterResult = true; resultRecord = nil
            }
        }
        .onAppear {
            confirmFrames = settings.confirmFrames
            startupFrames = settings.startupFrames
            responsePractice = settings.responsePractice
            startRound()
        }
        .onDisappear { generation += 1 }
    }

    // MARK: Subviews

    private var inlineSettings: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Text(mode.rawValue)
                    .font(.caption).foregroundColor(.secondary).lineLimit(1).minimumScaleFactor(0.7)
                Spacer()
                Stepper(value: $confirmFrames, in: 4...60) {
                    Text("判定 \(confirmFrames)F").font(.caption).monospacedDigit()
                }.frame(maxWidth: 160)
                if practiceType == .attack {
                    Stepper(value: $startupFrames, in: 1...60) {
                        Text("発生 \(startupFrames)F").font(.caption).monospacedDigit()
                    }.frame(maxWidth: 160)
                }
            }
            Picker("", selection: $responsePractice) {
                ForEach(ResponsePractice.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
        }
    }

    private var hpBar: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("HP").font(.caption2).foregroundColor(.secondary)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 5).fill(Color.gray.opacity(0.2))
                    // ダメージ赤フラッシュ（一時的に赤く）
                    if damageFlash > 0 {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color.red)
                            .frame(width: geo.size.width * min(hp + damageFlash, 1.0))
                    }
                    // 現在HP（HPバーモードのみアニメーション）
                    RoundedRectangle(cornerRadius: 5)
                        .fill(hp > 0.3 ? Color.green : Color.orange)
                        .frame(width: geo.size.width * max(hp, 0))
                        .animation(mode == .hpBar ? .easeOut(duration: 0.2) : nil, value: hp)
                }
            }.frame(height: 18)
        }
    }

    private var cueArea: some View {
        let (label, bg, fg) = cueVisuals()
        let useAnimation = (mode == .hpBar || mode == .sound)
        return ZStack {
            RoundedRectangle(cornerRadius: 14).fill(bg)
            if !label.isEmpty {
                Text(label).font(.system(size: 52, weight: .black)).foregroundColor(fg)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 130)
        .animation(useAnimation ? .easeOut(duration: 0.08) : nil, value: isCueActive)
    }

    private func cueVisuals() -> (String, Color, Color) {
        // フィードバック状態
        if let ok = feedbackOk {
            if mode == .sound {
                let answerLabel: String
                switch currentCue {
                case .hit:    answerLabel = "HIT"
                case .guard_: answerLabel = "GUARD"
                default:      answerLabel = "—"
                }
                return (ok ? "✓ \(answerLabel)" : "✗ \(answerLabel)",
                        ok ? Color.green.opacity(0.2) : Color.red.opacity(0.2),
                        ok ? .green : .red)
            }
            return (ok ? "✓" : "✗",
                    ok ? Color.green.opacity(0.2) : Color.red.opacity(0.2),
                    ok ? .green : .red)
        }

        // cueActive状態
        if isCueActive {
            switch mode {
            case .hpBar:
                // HPバーが主cue。エリアは薄いフラッシュのみ
                return ("", Color.gray.opacity(0.12), .clear)
            case .effect:
                // 瞬時切り替え（animationなし）
                switch currentCue {
                case .hit:    return ("", Color.yellow.opacity(0.9), .clear)
                case .guard_: return ("", Color.gray.opacity(0.55), .clear)
                case .impact: return ("", Color.white, .clear)
                default:      return ("", Color.gray.opacity(0.06), .clear)
                }
            case .sound:
                // 音が主cue。視覚は中立
                return ("♪", Color.blue.opacity(0.25), .blue)
            case .impact:
                switch currentCue {
                case .impact: return ("IMPACT!", Color.white, .black)
                default:      return ("", Color.gray.opacity(0.06), .clear)
                }
            }
        }

        // 待機状態
        switch phase {
        case .idle:         return ("攻撃ボタンを押せ",    Color.gray.opacity(0.06), .secondary)
        case .passiveReady: return ("次へを押して開始",    Color.gray.opacity(0.06), .secondary)
        case .startup:      return ("待機中...",           Color.gray.opacity(0.06), .secondary)
        default:            return ("",                    Color.gray.opacity(0.06), .clear)
        }
    }

    private var statsBar: some View {
        let rate = total > 0 ? Int(Double(successes) / Double(total) * 100) : 0
        let avgF = reactionFrames.isEmpty ? 0.0 : reactionFrames.reduce(0, +) / Double(reactionFrames.count)
        return HStack(spacing: 0) {
            MiniStat(title: "成功率", value: "\(rate)%",                      color: .green)
            MiniStat(title: "反応",   value: String(format: "%.1fF", avgF),   color: .blue)
            MiniStat(title: "連続",   value: "\(streak)",                     color: .orange)
            MiniStat(title: "最高",   value: "\(best)",                       color: .purple)
        }
    }

    @ViewBuilder
    private var actionArea: some View {
        // 攻撃ボタン（攻撃モードのみ）
        // idle/feedback → ラウンド開始、cueActive → ヒット確認（押す）
        if practiceType == .attack {
            BigButton(label: "攻 撃", color: isCueActive ? .orange : .blue,
                      enabled: isIdle || isFeedback || isCueActive) {
                onAttackTap()
            }
            .padding(.bottom, 12)
        }

        // 防御モード: 次へ（開始）+ 押す（応答）
        if practiceType == .defense {
            BigButton(label: "次 へ", color: .indigo,
                      enabled: isPassiveReady || isFeedback) {
                startNextCue()
            }
            .padding(.bottom, 12)

            RespButton(
                label: "押 す",
                sub: "コンボ継続",
                color: .green,
                enabled: isCueActive
            ) { respond(.press) }
        }
    }

    // MARK: Logic

    private func startRound() {
        currentCue = .neutral
        phase = practiceType == .attack ? .idle : .passiveReady
    }

    private func resetSession() {
        generation += 1
        total = 0; successes = 0; streak = 0; best = 0
        reactionFrames = []; hp = 0.7; damageFlash = 0
        startRound()
    }

    // 攻撃ボタン: cueActive → press（ヒット確認）/ idle・feedback → startup
    private func onAttackTap() {
        if isCueActive {
            respond(.press)
            return
        }
        guard isIdle || isFeedback else { return }
        launchStartup()
    }

    // 次へボタン（防御）: passiveReady / feedback → random wait → cue
    private func startNextCue() {
        let canStart: Bool = isPassiveReady || isFeedback
        guard canStart else { return }
        phase = .startup
        let g = generation
        let delay = Double.random(in: 0.5...2.0)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard self.generation == g, case .startup = self.phase else { return }
            self.activateCue()
        }
    }

    private func launchStartup() {
        phase = .startup
        let g = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + startupSec) {
            guard self.generation == g, case .startup = self.phase else { return }
            self.activateCue()
        }
    }

    private func activateCue() {
        currentCue = randomCue()
        cueStartTime = Date()
        phase = .cueActive

        // HPダメージ（ヒット時のみ）
        if currentCue == .hit {
            let dmg = Double.random(in: 0.08...0.13)
            damageFlash = dmg
            hp = max(0.05, hp - dmg)
            let g = generation
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                guard self.generation == g else { return }
                self.damageFlash = 0
            }
        }

        // 音モード: サウンド再生
        if mode == .sound {
            switch currentCue {
            case .hit:    TonePlayer.shared.playHit()
            case .guard_: TonePlayer.shared.playGuard()
            default: break
            }
        }

        // 判定窓タイムアウト（押さない = timeout）
        let g = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + confirmSec) {
            guard self.generation == g, case .cueActive = self.phase else { return }
            self.respond(.timeout)
        }
    }

    private func respond(_ action: ResponseAction) {
        guard case .cueActive = phase else { return }

        if action == .press {
            let ms = Date().timeIntervalSince(cueStartTime) * 1000
            reactionFrames.append(ms * 60.0 / 1000.0)
        }

        let ok = isCorrect(action: action)
        total += 1
        if ok { successes += 1; streak += 1; best = max(best, streak) } else { streak = 0 }
        phase = .feedback(ok)
        // 自動進行なし: 攻撃ボタン or 次へボタンで手動進行
    }

    private func isCorrect(action: ResponseAction) -> Bool {
        switch (mode, currentCue) {
        case (.hpBar,   .hit),
             (.effect,  .hit),
             (.sound,   .hit):    return action == .press
        case (.hpBar,   .guard_),
             (.effect,  .guard_),
             (.sound,   .guard_): return action == .timeout
        case (.impact,  .impact): return action == .press
        case (.impact,  .neutral): return action == .timeout
        default: return false
        }
    }

    private func randomCue() -> CueType {
        switch mode {
        case .hpBar, .effect, .sound:
            switch responsePractice {
            case .both:      return Bool.random() ? .hit : .guard_
            case .pressOnly: return .hit
            case .holdOnly:  return .guard_
            }
        case .impact:
            switch responsePractice {
            case .both:      return Bool.random() ? .impact : .neutral
            case .pressOnly: return .impact
            case .holdOnly:  return .neutral
            }
        }
    }

    private func endSession() {
        generation += 1
        let rate = total > 0 ? Double(successes) / Double(total) : 0
        let avgF = reactionFrames.isEmpty ? 0.0 : reactionFrames.reduce(0, +) / Double(reactionFrames.count)
        let rec = SessionRecord(mode: mode, practiceType: practiceType,
                                successRate: rate, avgReactionFrames: avgF,
                                bestStreak: best, totalAttempts: total)
        store.append(rec)
        resultRecord = rec
    }
}

// MARK: - Result View

struct ResultView: View {
    let record: SessionRecord
    let onPlayAgain: () -> Void
    let onHome: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Text("セッション結果").font(.title2.bold()).padding(.top, 48)
            VStack(spacing: 0) {
                resRow("モード",    record.mode.rawValue)
                Divider(); resRow("タイプ",    record.practiceType.rawValue)
                Divider(); resRow("成功率",    "\(Int(record.successRate * 100))%")
                Divider(); resRow("平均反応",  String(format: "%.1f F", record.avgReactionFrames))
                Divider(); resRow("最高連続",  "\(record.bestStreak) 回")
                Divider(); resRow("試行回数",  "\(record.totalAttempts) 回")
            }
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal)
            Spacer()
            VStack(spacing: 12) {
                BigButton(label: "もう一度", color: .blue,             enabled: true, action: onPlayAgain)
                BigButton(label: "ホームへ", color: Color(.systemGray4), enabled: true, action: onHome)
            }
            .padding(.horizontal).padding(.bottom, 48)
        }
    }

    private func resRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundColor(.secondary)
            Spacer()
            Text(value).bold()
        }
        .padding(.horizontal).padding(.vertical, 13)
    }
}

// MARK: - Records View

struct RecordsView: View {
    @EnvironmentObject var store: RecordsStore
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationView {
            Group {
                if store.records.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "chart.bar").font(.system(size: 48)).foregroundColor(.secondary)
                        Text("記録なし").foregroundColor(.secondary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(store.records) { r in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(r.mode.rawValue).font(.subheadline.bold())
                                Spacer()
                                Text(r.date, style: .relative).font(.caption).foregroundColor(.secondary)
                            }
                            HStack(spacing: 16) {
                                Label("\(Int(r.successRate * 100))%", systemImage: "checkmark.circle")
                                    .foregroundColor(.green)
                                Label(String(format: "%.1fF", r.avgReactionFrames), systemImage: "bolt")
                                    .foregroundColor(.blue)
                                Label("×\(r.bestStreak)", systemImage: "flame")
                                    .foregroundColor(.orange)
                            }.font(.caption)
                        }.padding(.vertical, 2)
                    }
                }
            }
            .navigationTitle("記録")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
    }
}

// MARK: - UI Components

struct BigButton: View {
    let label: String; let color: Color; let enabled: Bool; let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(label).font(.headline)
                .frame(maxWidth: .infinity, minHeight: 56)
                .background(enabled ? color : Color(.systemGray4))
                .foregroundColor(enabled ? .white : Color(.systemGray))
                .clipShape(RoundedRectangle(cornerRadius: 14))
        }.disabled(!enabled)
    }
}

struct RespButton: View {
    let label: String; let sub: String; let color: Color; let enabled: Bool; let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Text(sub).font(.caption2).opacity(0.7)
                Text(label).font(.headline)
            }
            .frame(maxWidth: .infinity, minHeight: 72)
            .background(enabled ? color : Color(.systemGray5))
            .foregroundColor(enabled ? .white : Color(.systemGray))
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .disabled(!enabled)
        .animation(.easeInOut(duration: 0.1), value: enabled)
    }
}

struct MiniStat: View {
    let title: String; let value: String; let color: Color
    var body: some View {
        VStack(spacing: 2) {
            Text(title).font(.caption2).foregroundColor(.secondary)
            Text(value).font(.system(.title3, design: .monospaced).bold()).foregroundColor(color)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 8)
        .background(color.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
