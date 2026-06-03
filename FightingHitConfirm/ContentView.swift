import SwiftUI

// MARK: - Models

enum PracticeType: String, CaseIterable, Codable {
    case passive = "受動型"
    case active  = "能動型"
}

enum DrillMode: String, CaseIterable, Codable {
    case simpleHit   = "単純ヒット確認"
    case hitAndGuard = "ヒット確認＆ガード別"
    case impact      = "インパクト確認"
}

enum CueType {
    case hit, guard_, impact, neutral
}

enum ResponseAction {
    case pressA, pressB, pressC, timeout
}

enum DrillPhase {
    case idle       // 能動型: 攻撃ボタン待ち
    case waiting    // 受動型: ランダム遅延中
    case startup    // 能動型: 発生フレーム遅延中
    case cueActive  // 判定窓オープン
    case feedback(Bool)  // 正誤フィードバック表示
}

struct DrillSettings: Codable {
    var practiceType: PracticeType = .passive
    var mode: DrillMode = .simpleHit
    var confirmFrames: Int = 18
    var startupFrames: Int = 8

    var confirmSeconds: Double { Double(confirmFrames) / 60.0 }
    var startupSeconds: Double { Double(startupFrames) / 60.0 }

    private static let key = "fhc_settings_v1"
    static func load() -> DrillSettings {
        guard let d = UserDefaults.standard.data(forKey: key),
              let s = try? JSONDecoder().decode(DrillSettings.self, from: d) else { return .init() }
        return s
    }
    func save() {
        if let d = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(d, forKey: Self.key)
        }
    }
}

struct SessionRecord: Codable, Identifiable {
    var id = UUID()
    var date = Date()
    var mode: DrillMode
    var practiceType: PracticeType
    var successRate: Double
    var avgReactionMs: Double
    var bestStreak: Int
    var totalAttempts: Int
}

// MARK: - Store

class RecordsStore: ObservableObject {
    @Published var records: [SessionRecord] = []
    private let key = "fhc_records_v1"
    init() { load() }
    func append(_ r: SessionRecord) { records.insert(r, at: 0); persist() }
    private func load() {
        guard let d = UserDefaults.standard.data(forKey: key),
              let v = try? JSONDecoder().decode([SessionRecord].self, from: d) else { return }
        records = v
    }
    private func persist() {
        if let d = try? JSONEncoder().encode(records) {
            UserDefaults.standard.set(d, forKey: key)
        }
    }
}

// MARK: - Root

struct ContentView: View {
    @StateObject private var store = RecordsStore()
    var body: some View {
        NavigationStack {
            StartView().environmentObject(store)
        }
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
            }

            Section("モード") {
                Picker("モード", selection: $settings.mode) {
                    ForEach(DrillMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }

            Section("判定窓") {
                Stepper(value: $settings.confirmFrames, in: 4...60) {
                    HStack {
                        Text("\(settings.confirmFrames) F")
                            .monospacedDigit().bold()
                        Text("≈ \(Int(settings.confirmSeconds * 1000)) ms")
                            .foregroundColor(.secondary).font(.footnote)
                    }
                }
            }

            if settings.practiceType == .active {
                Section("発生フレーム（能動型）") {
                    Stepper(value: $settings.startupFrames, in: 1...60) {
                        HStack {
                            Text("\(settings.startupFrames) F")
                                .monospacedDigit().bold()
                            Text("≈ \(Int(settings.startupSeconds * 1000)) ms")
                                .foregroundColor(.secondary).font(.footnote)
                        }
                    }
                }
            }

            Section {
                Button {
                    settings.save()
                    toPractice = true
                } label: {
                    HStack { Spacer(); Text("練習開始").font(.headline); Spacer() }
                }
            }
        }
        .navigationTitle("Hit Confirm")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("記録") { showRecords = true }
            }
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
    @State private var phase: DrillPhase = .idle
    @State private var currentCue: CueType = .neutral
    @State private var cueStartTime = Date()
    @State private var generation = 0

    @State private var total = 0
    @State private var successes = 0
    @State private var streak = 0
    @State private var best = 0
    @State private var reactionMs: [Double] = []
    @State private var hp: Double = 0.7

    @State private var resultRecord: SessionRecord? = nil
    @State private var goHomeAfterResult = false

    var mode: DrillMode { settings.mode }
    var practiceType: PracticeType { settings.practiceType }
    var confirmSec: Double { Double(confirmFrames) / 60.0 }
    var startupSec: Double { Double(startupFrames) / 60.0 }

    var isCueActive: Bool { if case .cueActive = phase { return true }; return false }
    var isIdle: Bool { if case .idle = phase { return true }; return false }

    var body: some View {
        VStack(spacing: 0) {
            inlineSettings
                .padding(.horizontal).padding(.top, 8)

            hpBar
                .padding(.horizontal).padding(.top, 12)

            cueArea
                .padding(.horizontal).padding(.top, 12)

            statsBar
                .padding(.horizontal).padding(.top, 12)

            Spacer()

            responseArea
                .padding(.horizontal).padding(.bottom, 32)
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
                goHomeAfterResult = false
                resultRecord = nil
            } onHome: {
                goHomeAfterResult = true
                resultRecord = nil
            }
        }
        .onAppear {
            confirmFrames = settings.confirmFrames
            startupFrames = settings.startupFrames
            startRound()
        }
        .onDisappear { generation += 1 }
    }

    // MARK: Subviews

    private var inlineSettings: some View {
        HStack(spacing: 8) {
            Text(settings.mode.rawValue)
                .font(.caption).foregroundColor(.secondary)
                .lineLimit(1).minimumScaleFactor(0.7)
            Spacer()
            Stepper(value: $confirmFrames, in: 4...60) {
                Text("判定 \(confirmFrames)F").font(.caption).monospacedDigit()
            }
            .frame(maxWidth: 160)
            if settings.practiceType == .active {
                Stepper(value: $startupFrames, in: 1...60) {
                    Text("発生 \(startupFrames)F").font(.caption).monospacedDigit()
                }
                .frame(maxWidth: 160)
            }
        }
    }

    private var hpBar: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("HP").font(.caption2).foregroundColor(.secondary)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 5).fill(Color.gray.opacity(0.2))
                    RoundedRectangle(cornerRadius: 5)
                        .fill(hp > 0.3 ? Color.green : Color.red)
                        .frame(width: geo.size.width * hp)
                        .animation(.easeOut(duration: 0.15), value: hp)
                }
            }
            .frame(height: 18)
        }
    }

    private var cueArea: some View {
        let (label, bg, fg) = cueVisuals()
        return Text(label)
            .font(.system(size: 52, weight: .black))
            .foregroundColor(fg)
            .frame(maxWidth: .infinity, minHeight: 130)
            .background(bg)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .animation(.easeOut(duration: 0.08), value: isCueActive)
    }

    private func cueVisuals() -> (String, Color, Color) {
        switch phase {
        case .feedback(let ok):
            return (ok ? "✓" : "✗",
                    ok ? Color.green.opacity(0.2) : Color.red.opacity(0.2),
                    ok ? .green : .red)
        case .cueActive:
            switch currentCue {
            case .hit:     return ("HIT",     Color.yellow.opacity(0.9), .black)
            case .guard_:  return ("GUARD",   Color.gray.opacity(0.55),  .white)
            case .impact:  return ("IMPACT!", Color.white,               .black)
            case .neutral: return ("—",       Color.gray.opacity(0.1),   .secondary)
            }
        case .idle:
            return ("攻撃ボタンを押せ", Color.gray.opacity(0.06), .secondary)
        default:
            return ("待機中...", Color.gray.opacity(0.06), .secondary)
        }
    }

    private var statsBar: some View {
        let rate = total > 0 ? Int(Double(successes) / Double(total) * 100) : 0
        let avg  = reactionMs.isEmpty ? 0 : Int(reactionMs.reduce(0, +) / Double(reactionMs.count))
        return HStack(spacing: 0) {
            MiniStat(title: "成功率", value: "\(rate)%",  color: .green)
            MiniStat(title: "反応",   value: "\(avg)ms",  color: .blue)
            MiniStat(title: "連続",   value: "\(streak)", color: .orange)
            MiniStat(title: "最高",   value: "\(best)",   color: .purple)
        }
    }

    @ViewBuilder
    private var responseArea: some View {
        if settings.practiceType == .active {
            BigButton(label: "攻 撃", color: .blue, enabled: isIdle) { onAttackTap() }
                .padding(.bottom, 12)
        }
        HStack(spacing: 12) {
            switch settings.mode {
            case .simpleHit:
                RespButton(label: "コンボ継続", sub: "A", color: .green, enabled: isCueActive) {
                    respond(.pressA)
                }
            case .hitAndGuard:
                RespButton(label: "ヒット継続", sub: "A", color: .green, enabled: isCueActive) {
                    respond(.pressA)
                }
                RespButton(label: "ガード停止", sub: "B", color: .orange, enabled: isCueActive) {
                    respond(.pressB)
                }
            case .impact:
                RespButton(label: "インパクト返し", sub: "C", color: .red, enabled: isCueActive) {
                    respond(.pressC)
                }
            }
        }
    }

    // MARK: Logic

    private func startRound() {
        currentCue = .neutral
        if practiceType == .active {
            phase = .idle
        } else {
            phase = .waiting
            schedulePassiveCue()
        }
    }

    private func resetSession() {
        generation += 1
        total = 0; successes = 0; streak = 0; best = 0
        reactionMs = []; hp = 0.7
        startRound()
    }

    private func schedulePassiveCue() {
        let g = generation
        let delay = Double.random(in: 0.5...2.0)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard self.generation == g, case .waiting = self.phase else { return }
            self.activateCue()
        }
    }

    private func onAttackTap() {
        guard isIdle else { return }
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

        if currentCue == .hit {
            withAnimation { hp = max(0.05, hp - Double.random(in: 0.08...0.13)) }
        }

        let g = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + confirmSec) {
            guard self.generation == g, case .cueActive = self.phase else { return }
            self.respond(.timeout)
        }
    }

    private func respond(_ action: ResponseAction) {
        guard case .cueActive = phase else { return }

        if action != .timeout {
            reactionMs.append(Date().timeIntervalSince(cueStartTime) * 1000)
        }

        let ok = isCorrect(action: action, cue: currentCue, mode: settings.mode)
        total += 1
        if ok { successes += 1; streak += 1; best = max(best, streak) } else { streak = 0 }
        phase = .feedback(ok)

        let g = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard self.generation == g else { return }
            self.startRound()
        }
    }

    private func isCorrect(action: ResponseAction, cue: CueType, mode: DrillMode) -> Bool {
        switch (mode, cue) {
        case (.simpleHit,   .hit):     return action == .pressA
        case (.simpleHit,   .guard_):  return action == .timeout
        case (.hitAndGuard, .hit):     return action == .pressA
        case (.hitAndGuard, .guard_):  return action == .pressB
        case (.impact,      .impact):  return action == .pressC
        case (.impact,      .neutral): return action == .timeout
        default: return false
        }
    }

    private func randomCue() -> CueType {
        switch settings.mode {
        case .simpleHit, .hitAndGuard: return Bool.random() ? .hit : .guard_
        case .impact:                  return Bool.random() ? .impact : .neutral
        }
    }

    private func endSession() {
        generation += 1
        let rate = total > 0 ? Double(successes) / Double(total) : 0
        let avg  = reactionMs.isEmpty ? 0.0 : reactionMs.reduce(0, +) / Double(reactionMs.count)
        let rec  = SessionRecord(
            mode: settings.mode,
            practiceType: settings.practiceType,
            successRate: rate,
            avgReactionMs: avg,
            bestStreak: best,
            totalAttempts: total
        )
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
            Text("セッション結果")
                .font(.title2.bold())
                .padding(.top, 48)

            VStack(spacing: 0) {
                resRow("モード",   record.mode.rawValue)
                Divider()
                resRow("タイプ",   record.practiceType.rawValue)
                Divider()
                resRow("成功率",   "\(Int(record.successRate * 100))%")
                Divider()
                resRow("平均反応", "\(Int(record.avgReactionMs)) ms")
                Divider()
                resRow("最高連続", "\(record.bestStreak) 回")
                Divider()
                resRow("試行回数", "\(record.totalAttempts) 回")
            }
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal)

            Spacer()

            VStack(spacing: 12) {
                BigButton(label: "もう一度", color: .blue, enabled: true, action: onPlayAgain)
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
                        Image(systemName: "chart.bar")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)
                        Text("記録なし").foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(store.records) { r in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(r.mode.rawValue).font(.subheadline.bold())
                                Spacer()
                                Text(r.date, style: .relative)
                                    .font(.caption).foregroundColor(.secondary)
                            }
                            HStack(spacing: 16) {
                                Label("\(Int(r.successRate * 100))%", systemImage: "checkmark.circle")
                                    .foregroundColor(.green)
                                Label("\(Int(r.avgReactionMs))ms", systemImage: "bolt")
                                    .foregroundColor(.blue)
                                Label("×\(r.bestStreak)", systemImage: "flame")
                                    .foregroundColor(.orange)
                            }
                            .font(.caption)
                        }
                        .padding(.vertical, 2)
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

// MARK: - Shared Components

struct BigButton: View {
    let label: String
    let color: Color
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 56)
                .background(enabled ? color : Color(.systemGray4))
                .foregroundColor(enabled ? .white : Color(.systemGray))
                .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .disabled(!enabled)
    }
}

struct RespButton: View {
    let label: String
    let sub: String
    let color: Color
    let enabled: Bool
    let action: () -> Void

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
    let title: String
    let value: String
    let color: Color

    var body: some View {
        VStack(spacing: 2) {
            Text(title).font(.caption2).foregroundColor(.secondary)
            Text(value)
                .font(.system(.title3, design: .monospaced).bold())
                .foregroundColor(color)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(color.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
