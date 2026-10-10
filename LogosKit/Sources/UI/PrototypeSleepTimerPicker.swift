// PROTOTYPE: throwaway, never merge. Lives on branch `prototype/sleep-timer-picker`.
//
// Question: what should choosing a Sleep Timer look like, now that the menu lists every Chapter left in the Book?
// Round 1 picked "A: a small sheet with a −/+ stepper". Round 2 varies A, switchable from a floating bar at the bottom
// of the player sheet (← / →), on in-memory scenarios (40 Chapters of varied length, single Chapter, last Chapter,
// near the end) so the long-list case and the edges can be seen without real audio. Choosing a timer only changes
// this in-memory model, never the Player.
//
// A1: the round-1 stepper sheet, as the baseline.
// A2: preset chips above the stepper; the headline is the wall-clock stop time.
// A3: a strip of the Book's Chapters (width by length) showing what will play; −/+ or tap a Chapter.
// A4: no sheet: the player's button row turns into an inline −/+ row.
// A5: set state first: a set timer opens on its status with a big +1 Chapter and Cancel; the stepper is behind
//     "Change". Unset, it is A1.

import Domain
import Observation
import SwiftUI

@Observable
final class PrototypeSleepModel {
    enum Variant: String, CaseIterable {
        case a1 = "A1 · Stepper sheet"
        case a2 = "A2 · Presets + clock time"
        case a3 = "A3 · Chapter strip"
        case a4 = "A4 · Inline row"
        case a5 = "A5 · Status first"
    }

    enum Scenario: String, CaseIterable {
        case long = "40 Chapters, in Ch 3"
        case single = "Single Chapter"
        case last = "In last Chapter"
        case nearEnd = "40 Chapters, in Ch 38"
    }

    var variant: Variant = .a1 {
        didSet { inlineOpen = false }
    }
    var scenario: Scenario = .long {
        didSet { timer = nil }
    }
    var timer: SleepTimer?
    /// A4: the player's button row is showing the inline stepper.
    var inlineOpen = false
    let rate: Float = 1.5

    /// 40 Chapters of 15–45 min, deterministic.
    private static let long: [Chapter] = {
        var start = 0.0
        return (0..<40).map { index in
            let length = Double(900 + (index * 7919) % 1800)
            defer { start += length }
            return Chapter(id: index, start: start, end: start + length, title: "Chapter \(index + 1)")
        }
    }()

    var bookDuration: Double {
        scenario == .single ? 9 * 3600 : Self.long.last!.end
    }

    var chapters: ChapterList {
        scenario == .single
            ? ChapterList([], bookDuration: bookDuration, bookTitle: "The Single-Chapter Book")
            : ChapterList(Self.long, bookDuration: bookDuration, bookTitle: "The Long Book")
    }

    var position: Double {
        switch scenario {
        case .long: Self.long[2].start + 600
        case .single: 3600
        case .last: Self.long[39].start + 300
        case .nearEnd: Self.long[37].start + 600
        }
    }

    var currentIndex: Int { chapters.index(at: position) }
    /// How many Chapters can be chosen: from this one to the last.
    var maxCount: Int { chapters.count - currentIndex }
    var currentCount: Int { timer.map { count(of: $0) } ?? 1 }

    func timer(count: Int) -> SleepTimer? {
        SleepTimer(chapters: count, from: position, in: chapters, bookDuration: bookDuration)
    }

    func count(of timer: SleepTimer) -> Int { timer.chapterIndex - currentIndex + 1 }

    func title(_ count: Int) -> String {
        count <= 1 ? "End of this Chapter" : "\(count) Chapters"
    }

    func left(_ count: Int) -> String {
        timer(count: count).map { BookDetailModel.duration($0.timeLeft(from: position, rate: rate)) } ?? ""
    }

    func stop(_ count: Int) -> String {
        guard let timer = timer(count: count) else { return "" }
        return timer.endsBook ? "end of Book" : "end of Chapter \(timer.chapterNumber)"
    }

    func projection(_ count: Int) -> String { "Stops at \(stop(count)) · ~\(left(count))" }

    /// "23:42", wall clock at the playing speed (prototype only: real code takes the Clock).
    func clockTime(_ count: Int) -> String {
        guard let timer = timer(count: count) else { return "" }
        return Date.now.addingTimeInterval(timer.timeLeft(from: position, rate: rate))
            .formatted(date: .omitted, time: .shortened)
    }

    func set(_ count: Int) { timer = timer(count: count) }
    func extend() { timer = timer.flatMap { $0.extended(in: chapters, bookDuration: bookDuration) } }
    func cancel() { timer = nil }
}

/// Stands in for `SleepTimerMenu` in the player sheet.
struct PrototypeSleepTimerButton: View {
    let model: PrototypeSleepModel
    @State private var showsSheet = false

    var body: some View {
        Button {
            if model.variant == .a4 {
                withAnimation(.snappy) { model.inlineOpen = true }
            } else {
                showsSheet = true
            }
        } label: {
            if let timer = model.timer {
                Label("Chapter \(timer.chapterNumber)", systemImage: "moon.zzz.fill")
            } else {
                Label("Sleep Timer", systemImage: "moon.zzz")
            }
        }
        .accessibilityLabel("Sleep Timer")
        .accessibilityValue(model.timer.map { model.projection(model.count(of: $0)) } ?? "Off")
        .sheet(isPresented: $showsSheet) {
            Group {
                switch model.variant {
                case .a1, .a4: PrototypeStepperSheet(model: model)
                case .a2: PrototypePresetsSheet(model: model)
                case .a3: PrototypeStripSheet(model: model)
                case .a5: PrototypeStatusSheet(model: model)
                }
            }
            .presentationDragIndicator(.visible)
        }
    }
}

// MARK: Shared pieces

/// The big count with −/+ either side; one adjustable element for VoiceOver.
struct PrototypeStepper: View {
    let model: PrototypeSleepModel
    @Binding var count: Int
    var size: CGFloat = 56

    var body: some View {
        HStack(spacing: 28) {
            stepButton("minus", enabled: count > 1) { count -= 1 }
            VStack(spacing: 2) {
                Text("\(count)")
                    .font(.system(size: size, weight: .semibold, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText(value: Double(count)))
                Text(count <= 1 ? "End of this Chapter" : "Chapters")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: 140)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Chapters")
            .accessibilityValue("\(model.title(count)), \(model.projection(count))")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: count = min(count + 1, model.maxCount)
                case .decrement: count = max(count - 1, 1)
                @unknown default: break
                }
            }
            stepButton("plus", enabled: count < model.maxCount) { count += 1 }
        }
        .animation(.snappy, value: count)
    }

    private func stepButton(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title2.bold())
                .frame(width: size, height: size)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .disabled(!enabled)
        .accessibilityHidden(true)
    }
}

/// Start (or Update) and, when a timer is set, Cancel.
struct PrototypeSheetActions: View {
    let model: PrototypeSleepModel
    let count: Int
    let done: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Button {
                model.set(count)
                done()
            } label: {
                Text(model.timer == nil ? "Start" : "Update").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            if model.timer != nil {
                Button("Cancel Sleep Timer", role: .destructive) {
                    model.cancel()
                    done()
                }
            }
        }
    }
}

// MARK: A1: stepper sheet

struct PrototypeStepperSheet: View {
    let model: PrototypeSleepModel
    @Environment(\.dismiss) private var dismiss
    @State private var count = 1

    var body: some View {
        VStack(spacing: 20) {
            Text("Sleep Timer").font(.headline).padding(.top, 20)
            PrototypeStepper(model: model, count: $count)
            Text(model.projection(count))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            PrototypeSheetActions(model: model, count: count) { dismiss() }
        }
        .padding(.horizontal, 24)
        .presentationDetents([.height(340)])
        .onAppear { count = model.currentCount }
    }
}

// MARK: A2: presets + clock time

struct PrototypePresetsSheet: View {
    let model: PrototypeSleepModel
    @Environment(\.dismiss) private var dismiss
    @State private var count = 1

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 4) {
                Text("Stops around \(model.clockTime(count))")
                    .font(.title2.bold().monospacedDigit())
                    .contentTransition(.numericText())
                Text("At \(model.stop(count)) · in ~\(model.left(count))")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 24)
            .accessibilityElement(children: .combine)
            HStack(spacing: 8) {
                ForEach([1, 2, 3, 5].filter { $0 <= model.maxCount }, id: \.self) { preset in
                    Button {
                        count = preset
                    } label: {
                        Text(preset == 1 ? "This Ch" : "\(preset)")
                            .frame(minWidth: 44)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .tint(count == preset ? .accentColor : .secondary)
                    .accessibilityLabel(model.title(preset))
                    .accessibilityAddTraits(count == preset ? .isSelected : [])
                }
            }
            PrototypeStepper(model: model, count: $count, size: 44)
            PrototypeSheetActions(model: model, count: count) { dismiss() }
        }
        .padding(.horizontal, 24)
        .presentationDetents([.height(400)])
        .animation(.snappy, value: count)
        .onAppear { count = model.currentCount }
    }
}

// MARK: A3: Chapter strip

struct PrototypeStripSheet: View {
    let model: PrototypeSleepModel
    @Environment(\.dismiss) private var dismiss
    @State private var count = 1

    var body: some View {
        let chapters = model.chapters.chapters
        let stopIndex = model.currentIndex + count - 1
        VStack(spacing: 16) {
            Text("Sleep Timer").font(.headline).padding(.top, 20)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .bottom, spacing: 3) {
                        ForEach(chapters.indices, id: \.self) { index in
                            bar(index, chapter: chapters[index], stopIndex: stopIndex)
                                .id(index)
                        }
                    }
                    .padding(.horizontal, 24)
                }
                .frame(height: 64)
                .padding(.horizontal, -24)
                .onChange(of: count, initial: true) {
                    withAnimation { proxy.scrollTo(stopIndex, anchor: .center) }
                }
            }
            .accessibilityHidden(true)
            VStack(spacing: 2) {
                Text(chapters[min(stopIndex, chapters.count - 1)].title).font(.title3.bold())
                Text(model.projection(count))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .accessibilityHidden(true)
            PrototypeStepper(model: model, count: $count, size: 40)
            PrototypeSheetActions(model: model, count: count) { dismiss() }
        }
        .padding(.horizontal, 24)
        .presentationDetents([.height(440)])
        .onAppear { count = model.currentCount }
    }

    private func bar(_ index: Int, chapter: Chapter, stopIndex: Int) -> some View {
        let current = model.currentIndex
        let color: Color =
            index < current ? .secondary.opacity(0.25) : index <= stopIndex ? .accentColor : .secondary.opacity(0.5)
        return VStack(spacing: 4) {
            Image(systemName: "moon.zzz.fill")
                .font(.caption2)
                .foregroundStyle(Color.accentColor)
                .opacity(index == stopIndex ? 1 : 0)
            RoundedRectangle(cornerRadius: 3)
                .fill(color)
                .frame(width: max(6, chapter.duration / 60), height: index == current ? 30 : 22)
        }
        .contentShape(.rect)
        .onTapGesture {
            if index >= current { count = index - current + 1 }
        }
        .animation(.snappy, value: stopIndex)
    }
}

// MARK: A4: inline row

/// Replaces the player's Sleep Timer / Chapters / Speed row while open.
struct PrototypeInlineRow: View {
    let model: PrototypeSleepModel
    @State private var count = 1

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                Button("Close", systemImage: "xmark") {
                    withAnimation(.snappy) { model.inlineOpen = false }
                }
                .labelStyle(.iconOnly)
                Spacer()
                Button("Fewer", systemImage: "minus") { count -= 1 }
                    .labelStyle(.iconOnly)
                    .disabled(count <= 1)
                    .accessibilityHidden(true)
                Text(model.title(count))
                    .font(.headline.monospacedDigit())
                    .frame(minWidth: 150)
                    .contentTransition(.numericText(value: Double(count)))
                    .accessibilityLabel("Chapters")
                    .accessibilityValue("\(model.title(count)), \(model.projection(count))")
                    .accessibilityAdjustableAction { direction in
                        switch direction {
                        case .increment: count = min(count + 1, model.maxCount)
                        case .decrement: count = max(count - 1, 1)
                        @unknown default: break
                        }
                    }
                Button("More", systemImage: "plus") { count += 1 }
                    .labelStyle(.iconOnly)
                    .disabled(count >= model.maxCount)
                    .accessibilityHidden(true)
                Spacer()
                Button(model.timer == nil ? "Start" : "Set", systemImage: "checkmark") {
                    model.set(count)
                    withAnimation(.snappy) { model.inlineOpen = false }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderedProminent)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            HStack {
                Text(model.projection(count))
                if model.timer != nil {
                    Text("·")
                    Button("Cancel", role: .destructive) {
                        model.cancel()
                        withAnimation(.snappy) { model.inlineOpen = false }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .animation(.snappy, value: count)
        .onAppear { count = model.currentCount }
    }
}

// MARK: A5: status first

struct PrototypeStatusSheet: View {
    let model: PrototypeSleepModel
    @Environment(\.dismiss) private var dismiss
    @State private var changing = false
    @State private var count = 1

    var body: some View {
        Group {
            if let timer = model.timer, !changing {
                let current = model.count(of: timer)
                VStack(spacing: 18) {
                    Image(systemName: "moon.zzz.fill")
                        .font(.largeTitle)
                        .foregroundStyle(Color.accentColor)
                        .padding(.top, 24)
                    VStack(spacing: 4) {
                        Text("Stops at \(model.stop(current))").font(.title3.bold())
                        Text("in ~\(model.left(current)) · \(model.title(current))")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    HStack(spacing: 12) {
                        Button {
                            model.extend()
                        } label: {
                            Label("+1 Chapter", systemImage: "plus").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(timer.extended(in: model.chapters, bookDuration: model.bookDuration) == nil)
                        Button(role: .destructive) {
                            model.cancel()
                            dismiss()
                        } label: {
                            Label("Cancel", systemImage: "xmark").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                    .controlSize(.large)
                    Button("Change…") {
                        count = current
                        withAnimation(.snappy) { changing = true }
                    }
                }
                .presentationDetents([.height(320)])
            } else {
                VStack(spacing: 20) {
                    Text("Sleep Timer").font(.headline).padding(.top, 20)
                    PrototypeStepper(model: model, count: $count)
                    Text(model.projection(count))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Button {
                        model.set(count)
                        dismiss()
                    } label: {
                        Text(model.timer == nil ? "Start" : "Update").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                .presentationDetents([.height(320)])
            }
        }
        .padding(.horizontal, 24)
        .onAppear { count = model.currentCount }
    }
}

// MARK: The floating switcher

/// Bottom bar: ← variant →, the scenario, and the model's state. Obviously not part of the design.
struct PrototypeSleepSwitcher: View {
    @Bindable var model: PrototypeSleepModel

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 12) {
                Button { cycle(-1) } label: { Image(systemName: "chevron.left") }
                Text(model.variant.rawValue).font(.caption.bold()).frame(minWidth: 170)
                Button { cycle(1) } label: { Image(systemName: "chevron.right") }
            }
            Picker("Scenario", selection: $model.scenario) {
                ForEach(PrototypeSleepModel.Scenario.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.menu)
            .font(.caption)
            Text(state).font(.caption2.monospaced()).foregroundStyle(.white.opacity(0.7))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .foregroundStyle(.white)
        .tint(.yellow)
        .background(.black.opacity(0.85), in: .rect(cornerRadius: 16))
        .shadow(radius: 8)
    }

    private var state: String {
        let chapter = "in Ch \(model.currentIndex + 1)/\(model.chapters.count) @\(model.rate)×"
        guard let timer = model.timer else { return "\(chapter) · timer: off" }
        return "\(chapter) · timer: \(model.count(of: timer)) → ends Ch \(timer.chapterNumber)"
    }

    private func cycle(_ step: Int) {
        let all = PrototypeSleepModel.Variant.allCases
        let index = all.firstIndex(of: model.variant)!
        model.variant = all[(index + step + all.count) % all.count]
    }
}
