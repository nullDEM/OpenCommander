#!/usr/bin/env python3
"""Generator danych do benchmarków OpenCommander (etap 0 planu optymalizacji).

Tworzy w podanym katalogu (domyślnie /tmp/oc-bench — poza iCloud) deterministyczny zestaw:
  flat_1k, flat_10k, flat_50k   płaskie foldery z małymi plikami o realistycznych nazwach (cyfry, polskie znaki, spacje)
  tree_a, tree_b                drzewa ~100 000 plików w ~2 500 folderach; tree_b = kopia tree_a z różnicami
                                (brakujące, dodatkowe i zmienione pliki) — do porównania folderów
  dups                          ~2 GB w plikach 1–80 MB: ~20 % duplikatów + pliki o tym samym rozmiarze i innej treści

Użycie:  python3 Tools/bench/make-data.py [katalog] [--skip-big]
Skrypt zapisuje tylko w podanym katalogu i odmawia pracy, jeśli katalog istnieje i nie zawiera znacznika.
"""
import os, random, sys, shutil

MARK = ".oc-bench-data"
SEED = 20261123

STEMS = ["Zdjęcie", "raport", "Faktura", "notatki", "Prezentacja", "umowa", "IMG", "Dokument", "zrzut ekranu",
         "Łódź-plan", "żółć test", "backup", "Projekt", "Ścieżka", "dane", "ćwiczenie", "Wideo", "log"]
EXTS = [".jpg", ".pdf", ".txt", ".docx", ".png", ".mov", ".zip", ".swift", ".md", ".xlsx", ".json", ""]


def name(rng, i):
    stem = rng.choice(STEMS)
    style = rng.randrange(4)
    if style == 0: n = f"{stem} {i}"
    elif style == 1: n = f"{stem}-{rng.randrange(2015, 2027)}-{rng.randrange(1, 13):02d} ({i})"
    elif style == 2: n = f"{stem}_{i:06d}"
    else: n = f"{stem} kopia {i}"
    return n + rng.choice(EXTS)


def write_small(path, rng):
    with open(path, "wb") as f:
        f.write(os.urandom(rng.randrange(0, 4096)))


def flat(root, count, rng):
    d = os.path.join(root, f"flat_{count // 1000}k")
    os.makedirs(d)
    for i in range(count):
        if i % 50 == 0:
            os.makedirs(os.path.join(d, f"Folder {i}"))
        else:
            write_small(os.path.join(d, name(rng, i)), rng)
    print(f"  {d}: {count}")


def tree(root, rng, folders=2500, per=40):
    a = os.path.join(root, "tree_a")
    paths = []
    for fi in range(folders):
        depth = fi % 4
        parts = [f"poziom{k}-{(fi >> (k * 2)) % 7}" for k in range(depth)] + [f"folder {fi}"]
        d = os.path.join(a, *parts)
        os.makedirs(d, exist_ok=True)
        for j in range(per):
            p = os.path.join(d, name(rng, fi * per + j))
            write_small(p, rng)
            paths.append(p)
    print(f"  {a}: {len(paths)} plików")
    b = os.path.join(root, "tree_b")
    shutil.copytree(a, b, copy_function=shutil.copy2)
    rel = [os.path.relpath(p, a) for p in paths]
    rng.shuffle(rel)
    k = len(rel) // 100  # po 1 % każdego rodzaju różnic
    for r in rel[:k]: os.remove(os.path.join(b, r))                       # tylko po lewej
    for r in rel[k:2 * k]:                                                # zmieniony rozmiar
        with open(os.path.join(b, r), "ab") as f: f.write(b"x")
    for i, r in enumerate(rel[2 * k:3 * k]):                              # tylko po prawej
        write_small(os.path.join(b, os.path.dirname(r), f"nowy {i}.txt"), rng)
    print(f"  {b}: kopia z różnicami ({k} usuniętych, {k} zmienionych, {k} nowych)")


def dups(root, rng, total_mb=2048):
    d = os.path.join(root, "dups")
    os.makedirs(os.path.join(d, "kopie"))
    written, uniques, i = 0, [], 0
    chunk = 1 << 20
    while written < total_mb * 0.8:
        mb = rng.randrange(1, 81)
        p = os.path.join(d, f"plik {i}.bin")
        with open(p, "wb") as f:
            for _ in range(mb): f.write(os.urandom(chunk))
        uniques.append((p, mb)); written += mb; i += 1
    # ~20 % duplikatów (prawdziwe kopie bajtów, nie klony APFS)
    for j, (p, mb) in enumerate(rng.sample(uniques, len(uniques) // 4)):
        if written >= total_mb: break
        shutil.copyfile(p, os.path.join(d, "kopie", f"kopia {j}.bin")); written += mb
    # ten sam rozmiar, ten sam początek i koniec, inny środek — wymusza pełny hash
    for j, (p, mb) in enumerate(uniques[:4]):
        if mb < 3: continue
        q = os.path.join(d, f"podobny {j}.bin")
        shutil.copyfile(p, q)
        with open(q, "r+b") as f:
            f.seek(mb * chunk // 2); f.write(os.urandom(4096))
        written += mb
    print(f"  {d}: ~{written} MB, {i} unikalnych")


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    root = os.path.abspath(args[0] if args else "/tmp/oc-bench")
    if os.path.exists(root):
        if not os.path.exists(os.path.join(root, MARK)):
            sys.exit(f"{root} istnieje i nie jest katalogiem danych benchmarku — przerywam.")
        shutil.rmtree(root)
    os.makedirs(root)
    open(os.path.join(root, MARK), "w").close()
    rng = random.Random(SEED)
    print(f"Dane w {root}")
    for n in (1_000, 10_000, 50_000): flat(root, n, rng)
    tree(root, rng)
    if "--skip-big" not in sys.argv: dups(root, rng)


if __name__ == "__main__":
    main()
