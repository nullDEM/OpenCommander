import SwiftUI
import OpenCommanderCore

/// Zbiorcza zmiana nazw z podglądem „przed → po”. Wykonanie jest zablokowane, dopóki którakolwiek pozycja ma problem.
struct BatchRenameSheet: View {
    let entries: [FileEntry]
    let state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var rule = BatchRenameRule()
    @State private var working = false
    @State private var report: String?

    private var plan: [BatchRenameItem] { BatchRename.plan(entries, rule: rule) }

    var body: some View {
        let items = plan
        let changes = items.filter { $0.status == .ok }.count
        let problems = items.filter { if case .problem = $0.status { return true } else { return false } }.count
        VStack(alignment: .leading, spacing: 12) {
            Text("Zmień nazwy: \(Polish.items(entries.count))").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Zamień").foregroundStyle(.secondary)
                    TextField("tekst do znalezienia", text: $rule.find).textFieldStyle(.roundedBorder)
                    Text("na").foregroundStyle(.secondary)
                    TextField("tekst zastępczy", text: $rule.replaceWith).textFieldStyle(.roundedBorder)
                    Toggle("Wielkość liter", isOn: $rule.caseSensitive).toggleStyle(.checkbox)
                }
                GridRow {
                    Text("Prefiks").foregroundStyle(.secondary)
                    TextField("", text: $rule.prefix).textFieldStyle(.roundedBorder)
                    Text("Sufiks").foregroundStyle(.secondary)
                    TextField("", text: $rule.suffix).textFieldStyle(.roundedBorder)
                    Picker("Litery", selection: $rule.caseMode) {
                        Text("bez zmian").tag(BatchRenameRule.CaseMode.none)
                        Text("małe").tag(BatchRenameRule.CaseMode.lower)
                        Text("WIELKIE").tag(BatchRenameRule.CaseMode.upper)
                        Text("Każde Słowo").tag(BatchRenameRule.CaseMode.words)
                    }.labelsHidden().frame(width: 130)
                }
                GridRow {
                    Text("Numeracja").foregroundStyle(.secondary)
                    Picker("", selection: $rule.numberPosition) {
                        Text("brak").tag(BatchRenameRule.NumberPosition.none)
                        Text("na początku").tag(BatchRenameRule.NumberPosition.prefix)
                        Text("na końcu").tag(BatchRenameRule.NumberPosition.suffix)
                    }.labelsHidden()
                    HStack {
                        Stepper("od \(rule.numberStart)", value: $rule.numberStart, in: 0...99999)
                    }
                    HStack {
                        Stepper("co \(rule.numberStep)", value: $rule.numberStep, in: 1...1000)
                    }
                    Stepper("cyfr: \(rule.numberDigits)", value: $rule.numberDigits, in: 1...8)
                }
            }
            .disabled(working)

            Table(items) {
                TableColumn("Przed") { Text($0.oldName).lineLimit(1).truncationMode(.middle) }
                TableColumn("Po") { item in
                    Text(item.newName).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(item.status == .unchanged ? .secondary : .primary)
                }
                TableColumn("Status") { item in
                    switch item.status {
                    case .ok: Label("OK", systemImage: "checkmark.circle").foregroundStyle(.green)
                    case .unchanged: Text("bez zmian").foregroundStyle(.secondary)
                    case .problem(let why): Label(why, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).lineLimit(2)
                    }
                }
                .width(min: 120, ideal: 230)
            }
            .frame(minHeight: 220)

            if let report { Text(report).font(.callout).foregroundStyle(.orange) }
            HStack {
                Text(problems > 0 ? "Popraw reguły — \(Polish.items(problems)) ma problem." : "Do zmiany: \(changes)")
                    .font(.callout).foregroundStyle(problems > 0 ? .red : .secondary)
                Spacer()
                Button("Anuluj", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Zmień nazwy") { apply(items) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || changes == 0 || problems > 0)
            }
        }
        .padding(20)
        .frame(minWidth: 760, minHeight: 520)
    }

    private func apply(_ items: [BatchRenameItem]) {
        working = true
        Task {
            let outcome = await state.applyBatchRename(items)
            working = false
            if outcome.failures.isEmpty { dismiss() }
            else { report = "Zmieniono \(outcome.renamed). Błędy:\n" + outcome.failures.joined(separator: "\n") }
        }
    }
}
