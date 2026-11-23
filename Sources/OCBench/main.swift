import Foundation
import OpenCommanderCore

// Benchmark logiki Core (etap 0 planu optymalizacji). Tylko odczyt danych z katalogu benchmarku.
// Uruchomienie (Release!):
//   python3 Tools/bench/make-data.py /tmp/oc-bench
//   swift run -c release --scratch-path /tmp/oc-spm-rel OCBench /tmp/oc-bench
// Wynik: mediana i minimum z kilku przebiegów (ms) + liczba elementów; na końcu szczytowa pamięć procesu.

let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "/tmp/oc-bench")
guard FileManager.default.fileExists(atPath: root.appendingPathComponent(".oc-bench-data").path) else {
    FileHandle.standardError.write("Brak danych benchmarku w \(root.path) — uruchom Tools/bench/make-data.py\n".data(using: .utf8)!)
    exit(1)
}
let only = CommandLine.arguments.dropFirst(2).first   // opcjonalny filtr nazw pomiarów

struct Row { var name: String; var median: Double; var min: Double; var runs: Int; var note: String }
var rows: [Row] = []

func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }

@discardableResult
func measure<T>(_ name: String, runs: Int = 5, note: (T) -> String = { _ in "" }, _ body: () throws -> T) rethrows -> T? {
    if let only, !name.contains(only) { return nil }
    let clock = ContinuousClock()
    var times: [Double] = []
    var last: T!
    _ = try body() // rozgrzewka (pamięć podręczna systemu plików, leniwe inicjalizacje)
    for _ in 0..<runs {
        var out: T!
        let t = clock.measure { out = try? body() }
        times.append(ms(t)); last = out
    }
    times.sort()
    let row = Row(name: name, median: times[times.count / 2], min: times[0], runs: runs, note: note(last))
    rows.append(row)
    print(String(format: "%-42@ %10.1f ms  (min %8.1f, n=%d)  %@", row.name as NSString, row.median, row.min, runs, row.note))
    return last
}

func dir(_ n: String) -> URL { root.appendingPathComponent(n) }

// 1. Listowanie folderów (DirectoryLister.listSync — to samo, co panel przy wejściu do folderu)
var lists: [String: [FileEntry]] = [:]
for n in ["flat_1k", "flat_10k", "flat_50k"] {
    if let e = try measure("listowanie \(n)", note: { "\($0.count) wpisów" }, { try DirectoryLister.listSync(dir(n), showHidden: false) }) {
        lists[n] = e
    }
}
let big = try lists["flat_50k"] ?? DirectoryLister.listSync(dir("flat_50k"), showHidden: false)

// 2. Sortowanie 50k (FileSorter.sorted — to samo, co zmiana kolumny sortowania)
for key in SortKey.allCases {
    measure("sortowanie 50k po \(key.rawValue) ↑", { FileSorter.sorted(big, by: key, ascending: true) })
}
measure("sortowanie 50k po name ↓", { FileSorter.sorted(big, by: .name, ascending: false) })
let sortedBig = FileSorter.sorted(big, by: .name, ascending: true)
measure("sortowanie 50k już posortowanej po name", { FileSorter.sorted(sortedBig, by: .name, ascending: true) })

// 3. Filtr 50k — symulacja pisania „raport 2” znak po znaku (każde naciśnięcie = jedno FileFilter.apply)
let typed = "raport 2"
measure("filtr 50k: pisanie „\(typed)” (\(typed.count) znaków)", runs: 5, note: { (n: Int) in "\(n) wyników na końcu" }) { () -> Int in
    var last = 0
    for i in 1...typed.count { last = FileFilter.apply(big, text: String(typed.prefix(i))).count }
    return last
}
measure("filtr 50k: „zolc” (składanie znaków)", note: { (r: [FileEntry]) in "\(r.count) wyników" }, { FileFilter.apply(big, text: "zolc") })

// 4. Drzewa: rozmiar folderu, porównanie, duplikaty
try measure("rozmiar folderu tree_a", runs: 3, note: { "\($0.files) plików, \($0.folders) folderów" }, { try FolderSizer.measureSync(dir("tree_a")) })
try measure("porównanie folderów tree_a ↔ tree_b", runs: 3, note: { "\($0.items.count) różnic" }, { try FolderComparison.compareSync(left: dir("tree_a"), right: dir("tree_b")) })
try measure("duplikaty tree_a (małe pliki)", runs: 3, note: { "\($0.count) grup" }, { try DuplicateFinder.findSync(in: dir("tree_a"), showHidden: false) })
try measure("duplikaty dups (~2,2 GB, ciepły cache)", runs: 3, note: { "\($0.count) grup" }, { try DuplicateFinder.findSync(in: dir("dups"), showHidden: false) })

// Szczytowa pamięć procesu (ru_maxrss w bajtach na macOS)
var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
print(String(format: "\nSzczytowa pamięć procesu: %.0f MB", Double(usage.ru_maxrss) / 1_048_576))

// Tabela Markdown do POMIARY.md
print("\n| Pomiar | Mediana [ms] | Min [ms] | n | Uwagi |\n|---|---:|---:|---:|---|")
for r in rows { print(String(format: "| %@ | %.1f | %.1f | %d | %@ |", r.name as NSString, r.median, r.min, r.runs, r.note as NSString)) }

// 5. Rozbicie kosztu listowania (diagnostyka etapu 0): które atrybuty są drogie
if only == nil || only!.contains("rozbicie") {
    let d = dir("flat_10k")
    let fm = FileManager.default
    let base: [URLResourceKey] = [.nameKey, .isDirectoryKey, .isSymbolicLinkKey, .isPackageKey, .isHiddenKey, .fileSizeKey, .contentModificationDateKey]
    func listWith(_ keys: [URLResourceKey]) throws -> Int {
        let urls = try fm.contentsOfDirectory(at: d, includingPropertiesForKeys: keys, options: [])
        var n = 0
        for u in urls { if (try? d.appendingPathComponent(u.lastPathComponent).resourceValues(forKeys: Set(keys))) != nil { n += 1 } }
        return n
    }
    try measure("rozbicie 10k: same nazwy (contentsOfDirectory)", { try fm.contentsOfDirectory(atPath: d.path).count })
    try measure("rozbicie 10k: podstawowe atrybuty", { try listWith(base) })
    try measure("rozbicie 10k: + contentTypeKey", { try listWith(base + [.contentTypeKey]) })
    try measure("rozbicie 10k: + localizedTypeDescriptionKey", { try listWith(base + [.localizedTypeDescriptionKey]) })
    try measure("rozbicie 10k: komplet (jak DirectoryLister)", { try listWith(base + [.contentTypeKey, .localizedTypeDescriptionKey]) })
    try measure("rozbicie 10k: podstawowe, URL z listy (bez appendingPathComponent)", {
        try fm.contentsOfDirectory(at: d, includingPropertiesForKeys: base, options: []).filter { (try? $0.resourceValues(forKeys: Set(base))) != nil }.count })
}
