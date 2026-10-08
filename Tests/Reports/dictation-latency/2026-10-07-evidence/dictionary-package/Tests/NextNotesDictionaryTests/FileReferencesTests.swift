import Foundation
import Testing

@testable import NextNotesDictionary

/// `FileReferences` rides on the `SpokenFormsTests` suite name so the existing
/// `--filter SpokenFormsTests` in the Makefile and CI runs it; a suite of its own would be
/// skipped by both, green and unexecuted.
///
/// One screen for every case, on purpose. Real projects put a login.ts next to a login.css, two
/// helpers.ts in different folders, and folders named like ordinary nouns, and a rule that only
/// works when nothing else on screen resembles the file is not a rule. The cases are grouped by
/// what they exercise; a case whose expected text equals its input must be left alone.
///
/// Built against the real tagger on 2026-09-16, when every group but the negatives started out
/// failing somewhere — see `FileReferences` for what each failure taught.
extension SpokenFormsTests {
    static let fileScreen = [
    "src/auth/loginHandler.ts", "src/auth/loginHandler.test.ts", "src/auth/login.css",
    "src/components/UserProfile.tsx", "src/components/user-card.jsx", "server/index.js",
    "scripts/deploy.sh", "scripts/data_loader.py", "api/main.go", "api/parser.rs",
    "android/MainActivity.kt", "app/models/user.rb", "public/index.php", "public/index.html",
    "native/matrix.c", "native/matrix.h", "native/renderer.cpp", "native/renderer.hpp",
    "ios/AppDelegate.m", "ios/Bridge.mm", "db/schema.sql", "db/v2-migration.sql",
    "notes/meeting-notes.txt", "data/users.csv", "assets/logo.png", "assets/logo.svg",
    "assets/photo.jpg", "assets/banner.jpeg", "docs/invoice-2024.pdf", "config/settings.toml",
    "docker-compose.yml", ".github/workflows/ci.yaml", "package.json", "package-lock.json",
    "Cargo.lock", "tsconfig.json", "vite.config.ts", "src/types.d.ts", ".eslintrc.json",
    ".env.local", "Dockerfile", "Makefile", "README.md", "CHANGELOG.md",
    "Sources/APIClient.swift", "docs/café-menu.md", "src/fileStore.ts", "styles/theme.scss",
    "data/report.xlsx", "media/demo.mp4", "roadmap/PAID-RELEASE.md", "roadmap/Next_Notes_v1_Roadmap.md", "roadmap/Next_Notes_v2_Roadmap.md", "docs/acoustic-echo.md", "ui/Button.ts", "ui/Button.tsx", "vendor/jquery.min.js", "release.md", "src/utils/helpers.ts", "tests/utils/helpers.ts",
    "src", "docs", "assets", "scripts", "notes", "data", "notes/a.txt",
]

    struct FileCase: CustomTestStringConvertible, Sendable {
        let group: String
        let input: String
        let expected: String
        var testDescription: String { "[\(group)] \(input.replacingOccurrences(of: "\n", with: "⏎"))" }
    }

    static let fileCases: [FileCase] = [
        // ── Extensions, said as letters after "dot" ──
        FileCase(group: "ext", input: "Open login handler dot ts.", expected: "Open @src/auth/loginHandler.ts."),
        FileCase(group: "ext", input: "Run the login handler test dot ts.", expected: "Run the @src/auth/loginHandler.test.ts."),
        FileCase(group: "ext", input: "Fix the login dot css file.", expected: "Fix the @src/auth/login.css file."),
        FileCase(group: "ext", input: "Open the user profile dot tsx.", expected: "Open the @src/components/UserProfile.tsx."),
        FileCase(group: "ext", input: "Update the user card dot jsx.", expected: "Update the @src/components/user-card.jsx."),
        FileCase(group: "ext", input: "Check the server index dot js.", expected: "Check the @server/index.js."),
        FileCase(group: "ext", input: "Run deploy dot sh.", expected: "Run @scripts/deploy.sh."),
        FileCase(group: "ext", input: "Open main dot go.", expected: "Open @api/main.go."),
        FileCase(group: "ext", input: "Open parser dot rs.", expected: "Open @api/parser.rs."),
        FileCase(group: "ext", input: "Open main activity dot kt.", expected: "Open @android/MainActivity.kt."),
        FileCase(group: "ext", input: "Check user dot rb.", expected: "Check @app/models/user.rb."),
        FileCase(group: "ext", input: "Open index dot php.", expected: "Open @public/index.php."),
        FileCase(group: "ext", input: "Open index dot html.", expected: "Open @public/index.html."),
        FileCase(group: "ext", input: "Open matrix dot c.", expected: "Open @native/matrix.c."),
        FileCase(group: "ext", input: "Open matrix dot h.", expected: "Open @native/matrix.h."),
        FileCase(group: "ext", input: "Open renderer dot cpp.", expected: "Open @native/renderer.cpp."),
        FileCase(group: "ext", input: "Open renderer dot hpp.", expected: "Open @native/renderer.hpp."),
        FileCase(group: "ext", input: "Open app delegate dot m.", expected: "Open @ios/AppDelegate.m."),
        FileCase(group: "ext", input: "Open bridge dot mm.", expected: "Open @ios/Bridge.mm."),
        FileCase(group: "ext", input: "Run schema dot sql.", expected: "Run @db/schema.sql."),
        FileCase(group: "ext", input: "Apply the v2 migration dot sql.", expected: "Apply the @db/v2-migration.sql."),
        FileCase(group: "ext", input: "Read meeting notes dot txt.", expected: "Read @notes/meeting-notes.txt."),
        FileCase(group: "ext", input: "Load users dot csv.", expected: "Load @data/users.csv."),
        FileCase(group: "ext", input: "Use logo dot png.", expected: "Use @assets/logo.png."),
        FileCase(group: "ext", input: "Use logo dot svg.", expected: "Use @assets/logo.svg."),
        FileCase(group: "ext", input: "Open photo dot jpg.", expected: "Open @assets/photo.jpg."),
        FileCase(group: "ext", input: "Open banner dot jpeg.", expected: "Open @assets/banner.jpeg."),
        FileCase(group: "ext", input: "Open invoice 2024 dot pdf.", expected: "Open @docs/invoice-2024.pdf."),
        FileCase(group: "ext", input: "Edit settings dot toml.", expected: "Edit @config/settings.toml."),
        FileCase(group: "ext", input: "Edit docker compose dot yml.", expected: "Edit @docker-compose.yml."),
        FileCase(group: "ext", input: "Edit ci dot yaml.", expected: "Edit @.github/workflows/ci.yaml."),
        FileCase(group: "ext", input: "Open package dot json.", expected: "Open @package.json."),
        FileCase(group: "ext", input: "Open package lock dot json.", expected: "Open @package-lock.json."),
        FileCase(group: "ext", input: "Open cargo dot lock.", expected: "Open @Cargo.lock."),
        FileCase(group: "ext", input: "Open ts config dot json.", expected: "Open @tsconfig.json."),
        FileCase(group: "ext", input: "Open vite config dot ts.", expected: "Open @vite.config.ts."),
        FileCase(group: "ext", input: "Open types dot d dot ts.", expected: "Open @src/types.d.ts."),
        FileCase(group: "ext", input: "Open eslint rc dot json.", expected: "Open @.eslintrc.json."),
        FileCase(group: "ext", input: "Read the readme dot md.", expected: "Read the @README.md."),
        FileCase(group: "ext", input: "Open API client dot swift.", expected: "Open @Sources/APIClient.swift."),
        FileCase(group: "ext", input: "Open the café menu dot md.", expected: "Open the @docs/café-menu.md."),
        FileCase(group: "ext", input: "Edit theme dot scss.", expected: "Edit @styles/theme.scss."),
        FileCase(group: "ext", input: "Open report dot xlsx.", expected: "Open @data/report.xlsx."),
        FileCase(group: "ext", input: "Play demo dot mp4.", expected: "Play @media/demo.mp4."),
        // ── Extensions as cleanup / ASR writes them ──
        FileCase(group: "written", input: "Open loginHandler.ts.", expected: "Open @src/auth/loginHandler.ts."),
        FileCase(group: "written", input: "Open LOGIN.CSS now.", expected: "Open @src/auth/login.css now."),
        FileCase(group: "written", input: "Open types.d.ts.", expected: "Open @src/types.d.ts."),
        FileCase(group: "written", input: "Open vite.config.ts.", expected: "Open @vite.config.ts."),
        FileCase(group: "written", input: "Open docker-compose.yml.", expected: "Open @docker-compose.yml."),
        FileCase(group: "written", input: "Open v2-migration.sql.", expected: "Open @db/v2-migration.sql."),
        FileCase(group: "written", input: "Open Cargo.lock.", expected: "Open @Cargo.lock."),
        FileCase(group: "written", input: "Open .eslintrc.json.", expected: "Open @.eslintrc.json."),
        FileCase(group: "written", input: "Open data_loader.py.", expected: "Open @scripts/data_loader.py."),
        // ── Extensions said as the language / format name ──
        FileCase(group: "spoken", input: "Open the data loader python file.", expected: "Open the @scripts/data_loader.py file."),
        FileCase(group: "spoken", input: "Open the user profile typescript file.", expected: "Open the @src/components/UserProfile.tsx file."),
        FileCase(group: "spoken", input: "Open the index HTML file.", expected: "Open the @public/index.html file."),
        FileCase(group: "spoken", input: "Open the global CSS file.", expected: "Open the global CSS file."),
        FileCase(group: "spoken", input: "Edit the docker compose yaml file.", expected: "Edit the @docker-compose.yml file."),
        FileCase(group: "spoken", input: "Open the package JSON.", expected: "Open the @package.json."),
        FileCase(group: "spoken", input: "Open the banner JPG.", expected: "Open the @assets/banner.jpeg."),
        FileCase(group: "spoken", input: "Open the readme markdown.", expected: "Open the @README.md."),
        FileCase(group: "spoken", input: "Run the deploy shell script.", expected: "Run the @scripts/deploy.sh script."),
        FileCase(group: "spoken", input: "Open the parser rust file.", expected: "Open the @api/parser.rs file."),
        FileCase(group: "spoken", input: "Open the main activity kotlin file.", expected: "Open the @android/MainActivity.kt file."),
        FileCase(group: "spoken", input: "Check the user ruby file.", expected: "Check the @app/models/user.rb file."),
        FileCase(group: "spoken", input: "Read the meeting notes text file.", expected: "Read the @notes/meeting-notes.txt file."),
        // ── Without an extension ──
        FileCase(group: "noext", input: "Open the login handler file.", expected: "Open the @src/auth/loginHandler.ts file."),
        FileCase(group: "noext", input: "Open the changelog file.", expected: "Open the @CHANGELOG.md file."),
        FileCase(group: "noext", input: "Update the changelog.", expected: "Update the changelog."),
        FileCase(group: "noext", input: "Tag login css.", expected: "Tag @src/auth/login.css."),
        FileCase(group: "noext", input: "Open the Dockerfile.", expected: "Open the @Dockerfile."),
        FileCase(group: "noext", input: "Update the Makefile.", expected: "Update the @Makefile."),
        FileCase(group: "noext", input: "Open the env local file.", expected: "Open the @.env.local file."),
        FileCase(group: "noext", input: "Open the file store dot ts.", expected: "Open the @src/fileStore.ts."),
        // ── Ties: several files match equally ──
        FileCase(group: "tie", input: "Open the logo file.", expected: "Open the logo file."),
        FileCase(group: "tie", input: "Open helpers dot ts.", expected: "Open helpers dot ts."),
        FileCase(group: "tie", input: "Open the matrix file.", expected: "Open the matrix file."),
        FileCase(group: "tie", input: "Open the renderer file.", expected: "Open the renderer file."),
        // ── Sentence shapes ──
        FileCase(group: "shape", input: "Compare logo.png and logo.svg.", expected: "Compare @assets/logo.png and @assets/logo.svg."),
        FileCase(group: "shape", input: "Is it in (login.css)?", expected: "Is it in (@src/auth/login.css)?"),
        FileCase(group: "shape", input: "Open \"login.css\" please.", expected: "Open \"@src/auth/login.css\" please."),
        FileCase(group: "shape", input: "Open login.css, then deploy.sh.", expected: "Open @src/auth/login.css, then @scripts/deploy.sh."),
        FileCase(group: "shape", input: "Login dot css is broken!", expected: "@src/auth/login.css is broken!"),
        FileCase(group: "shape", input: "Open login.css\nthen deploy.sh", expected: "Open @src/auth/login.css\nthen @scripts/deploy.sh"),
        FileCase(group: "shape", input: "The login.css's colors are off.", expected: "The @src/auth/login.css's colors are off."),
        FileCase(group: "shape", input: "Open src slash auth slash login dot css.", expected: "Open @src/auth/login.css."),
        FileCase(group: "shape", input: "Open login.css: it is broken.", expected: "Open @src/auth/login.css: it is broken."),
        FileCase(group: "shape", input: "Open login.css; then stop.", expected: "Open @src/auth/login.css; then stop."),
        // ── Already a reference ──
        FileCase(group: "existing", input: "Already @src/auth/login.css done.", expected: "Already @src/auth/login.css done."),
        FileCase(group: "existing", input: "Already `src/auth/login.css` done.", expected: "Already `src/auth/login.css` done."),
        FileCase(group: "existing", input: "See src/auth/login.css now.", expected: "See src/auth/login.css now."),
        // ── Ordinary sentences with format words or basenames in them ──
        FileCase(group: "negative", input: "Let's go to the store.", expected: "Let's go to the store."),
        FileCase(group: "negative", input: "I love python.", expected: "I love python."),
        FileCase(group: "negative", input: "Write it in typescript.", expected: "Write it in typescript."),
        FileCase(group: "negative", input: "Save the file.", expected: "Save the file."),
        FileCase(group: "negative", input: "Send me the logo.", expected: "Send me the logo."),
        FileCase(group: "negative", input: "Open the index.", expected: "Open the index."),
        FileCase(group: "negative", input: "Run the tests.", expected: "Run the tests."),
        FileCase(group: "negative", input: "The docs are in the assets folder.", expected: "The docs are in the assets folder."),
        FileCase(group: "negative", input: "Check your email and text me.", expected: "Check your email and text me."),
        FileCase(group: "negative", input: "The build uses rust and go.", expected: "The build uses rust and go."),
        FileCase(group: "negative", input: "Update the user.", expected: "Update the user."),
        FileCase(group: "negative", input: "Add a photo to the notes.", expected: "Add a photo to the notes."),
        FileCase(group: "negative", input: "Update the package.", expected: "Update the package."),
        FileCase(group: "negative", input: "The data looks right.", expected: "The data looks right."),
        FileCase(group: "negative", input: "Look at the settings.", expected: "Look at the settings."),
        FileCase(group: "negative", input: "Deploy it to main.", expected: "Deploy it to main."),
        FileCase(group: "negative", input: "Parse the report and send it.", expected: "Parse the report and send it."),
        FileCase(group: "negative", input: "Let's go open login.css.", expected: "Let's go open @src/auth/login.css."),
        FileCase(group: "negative", input: "Save a file.", expected: "Save a file."),
        FileCase(group: "negative", input: "Read the license.", expected: "Read the license."),
        FileCase(group: "short", input: "Open a dot txt.", expected: "Open @notes/a.txt."),
        FileCase(group: "short", input: "Tag ci yaml.", expected: "Tag @.github/workflows/ci.yaml."),
        FileCase(group: "real", input: "What is inside of the paid release that defied?", expected: "What is inside of the @roadmap/PAID-RELEASE.md that defied?"),
        FileCase(group: "real", input: "Can you read the next note v1 roadmap md?", expected: "Can you read the @roadmap/Next_Notes_v1_Roadmap.md?"),
        FileCase(group: "real", input: "You check the paid release.md file.", expected: "You check the @roadmap/PAID-RELEASE.md file."),
        FileCase(group: "real", input: "What is inside of the acoustic dash echo dot md file?", expected: "What is inside of the @docs/acoustic-echo.md file?"),
        FileCase(group: "real", input: "Check the next notes roadmap.", expected: "Check the next notes roadmap."),
        // ── Adversarial: sentence boundaries must not join words ──
        FileCase(group: "boundary", input: "Update the user. Card games are fun.", expected: "Update the user. Card games are fun."),
        FileCase(group: "boundary", input: "Open the login. CSS is broken.", expected: "Open the login. CSS is broken."),
        FileCase(group: "boundary", input: "Check the data, loader is fine.", expected: "Check the data, loader is fine."),
        FileCase(group: "boundary", input: "Use the logo; png later.", expected: "Use the logo; png later."),
        FileCase(group: "boundary", input: "Open the index\nfile", expected: "Open the index\nfile"),
        FileCase(group: "boundary", input: "Is it logo? File it.", expected: "Is it logo? File it."),
        FileCase(group: "boundary", input: "Tag. Login dot css.", expected: "Tag. @src/auth/login.css."),
        // ── Adversarial: offsets, near-twins, repeats ──
        FileCase(group: "offsets", input: "🎉 Open login.css now.", expected: "🎉 Open @src/auth/login.css now."),
        FileCase(group: "offsets", input: "Café 🎉 then deploy dot sh.", expected: "Café 🎉 then @scripts/deploy.sh."),
        FileCase(group: "twins", input: "Open button dot tsx.", expected: "Open @ui/Button.tsx."),
        FileCase(group: "twins", input: "Open button dot ts.", expected: "Open @ui/Button.ts."),
        FileCase(group: "twins", input: "Open the button typescript file.", expected: "Open the button typescript file."),
        FileCase(group: "twins", input: "Open jquery min js.", expected: "Open @vendor/jquery.min.js."),
        FileCase(group: "twins", input: "Open the index file.", expected: "Open the index file."),
        FileCase(group: "repeat", input: "Compare login.css with login.css.", expected: "Compare @src/auth/login.css with @src/auth/login.css."),
        FileCase(group: "repeat", input: "Open index dot html and index dot js.", expected: "Open @public/index.html and @server/index.js."),
        FileCase(group: "trigger", input: "Tag the release.", expected: "Tag the release."),
        FileCase(group: "trigger", input: "Tag release.", expected: "Tag @release.md."),
        FileCase(group: "trigger", input: "Open the settings dot.", expected: "Open the settings dot."),
    ]

    @Test("every format, name shape and sentence shape on a crowded screen", arguments: fileCases)
    func fileReferenceMatrix(_ testCase: FileCase) {
        let tagged = FileReferences.tag(testCase.input, references: Self.fileScreen, style: .atPath)
        #expect(tagged.text == testCase.expected)
    }

    @Test("backtick style writes the same references in backticks")
    func backtickStyle() {
        #expect(FileReferences.tag("Open the acoustic echo file.", references: Self.fileScreen, style: .backtickPath).text
            == "Open the `docs/acoustic-echo.md` file.")
        #expect(FileReferences.tag("Open login.css, then deploy.sh.", references: Self.fileScreen, style: .backtickPath).text
            == "Open `src/auth/login.css`, then `scripts/deploy.sh`.")
    }

    @Test("the references written are reported in order")
    func reportsReferences() {
        let tagged = FileReferences.tag("Open login.css, then deploy.sh.", references: Self.fileScreen, style: .atPath)
        #expect(tagged.references == ["src/auth/login.css", "scripts/deploy.sh"])
    }

    @Test("the harvest's file flag decides, not the string")
    func harvestDecidesFiles() {
        let candidates = [
            FileReferences.Candidate(reference: "LICENSE", isFile: true),
            FileReferences.Candidate(reference: "notes.md", isFile: false),
        ]
        // An extensionless file that is an ordinary word needs "file" or "tag".
        #expect(FileReferences.tag("Update the license file.", candidates: candidates, style: .atPath).text
            == "Update the @LICENSE file.")
        #expect(FileReferences.tag("Read the license.", candidates: candidates, style: .atPath).text
            == "Read the license.")
        // Something the harvest called a folder is never tagged, whatever it looks like.
        #expect(FileReferences.tag("Open notes dot md.", candidates: candidates, style: .atPath).text
            == "Open notes dot md.")
    }

    @Test("the loose match only runs for the names the caller allows")
    func looseMatchLimit() {
        let misheard = "Can you read the next note v1 roadmap md?"
        let roadmap = ["roadmap/Next_Notes_v1_Roadmap.md"]
        #expect(FileReferences.tag(misheard, references: roadmap, style: .atPath).text
            == "Can you read the @roadmap/Next_Notes_v1_Roadmap.md?")
        #expect(FileReferences.tag(misheard, references: roadmap, style: .atPath, looseMatchLimit: 0).text
            == misheard)
        // The exact pass is not limited.
        #expect(FileReferences.tag("Open login dot css.", references: ["src/auth/login.css"], style: .atPath, looseMatchLimit: 0).text
            == "Open @src/auth/login.css.")
    }

    @Test("empty text and an empty screen change nothing")
    func emptyInputs() {
        #expect(FileReferences.tag("", references: Self.fileScreen, style: .atPath).text == "")
        #expect(FileReferences.tag("Open login dot css.", references: [], style: .atPath).text == "Open login dot css.")
    }

    @Test("what counts as a file from the string alone")
    func fileDetection() {
        #expect(FileReferences.isFile("docs/index.html"))
        #expect(FileReferences.isFile("media/demo.mp4"))
        #expect(FileReferences.isFile(".eslintrc.json"))
        #expect(FileReferences.isFile("Dockerfile"))
        #expect(FileReferences.isFile("Makefile"))
        #expect(!FileReferences.isFile("docs"))
        #expect(!FileReferences.isFile(".gitignore"))
        #expect(!FileReferences.isFile("LICENSE"))
        #expect(!FileReferences.isFile("v1.2"))
    }
}
