// swift-tools-version:5.9
import PackageDescription

// Кроссплатформенный тестовый пакет чистой логики кошелька.
//
// Исходники НЕ дублируются: target указывает на те же файлы, которые Xcode
// компилирует в приложении через синхронизированную группу `GrinFlint`.
// Пакет не входит в Xcode-проект и не влияет на сборку приложения; его задача —
// быстрые `swift test` под Windows/Linux без macOS и симулятора.
//
// Запуск: swift test (в корне репозитория).
let package = Package(
    name: "GrinFlintCore",
    platforms: [
        .macOS(.v13),
        .iOS(.v17),
    ],
    targets: [
        .target(
            name: "GrinFlintCore",
            path: "GrinFlintApp/GrinFlint/Core"
        ),
        .testTarget(
            name: "GrinFlintCoreTests",
            dependencies: ["GrinFlintCore"],
            path: "Tests/GrinFlintCoreTests"
        ),
    ]
)
