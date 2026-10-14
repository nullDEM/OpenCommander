// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OpenCommanderCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "OpenCommanderCore", targets: ["OpenCommanderCore"]),
        .library(name: "OpenCommanderRemote", targets: ["OpenCommanderRemote"])
    ],
    dependencies: [
        // SFTP (SSH). MIT. Dokładna wersja przypięta; zależności tranzytywne przypina Package.resolved (w repozytorium).
        .package(url: "https://github.com/orlandos-nl/Citadel.git", exact: "0.12.1")
    ],
    targets: [
        // Systemowy libcurl (FTP/FTPS). Nie jest dołączany do aplikacji — to biblioteka systemu macOS.
        .systemLibrary(name: "CCurl", path: "Sources/CCurl"),
        // Czysta logika: modele, silnik operacji, profile, Keychain. Bez zależności zewnętrznych.
        .target(name: "OpenCommanderCore", path: "Sources/OpenCommanderCore"),
        // Protokoły sieciowe: SFTP (Citadel), WebDAV (URLSession), FTP/FTPS (systemowy libcurl).
        .target(
            name: "OpenCommanderRemote",
            dependencies: [
                "OpenCommanderCore", "CCurl",
                .product(name: "Citadel", package: "Citadel")
            ],
            path: "Sources/OpenCommanderRemote"
        ),
        .testTarget(
            name: "OpenCommanderCoreTests",
            dependencies: ["OpenCommanderCore"],
            path: "Tests/OpenCommanderCoreTests"
        ),
        .testTarget(
            name: "OpenCommanderRemoteTests",
            dependencies: [
                "OpenCommanderRemote", "OpenCommanderCore",
                .product(name: "Citadel", package: "Citadel")
            ],
            path: "Tests/OpenCommanderRemoteTests"
        )
    ]
)
