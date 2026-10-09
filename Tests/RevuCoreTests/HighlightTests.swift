import Testing
@testable import RevuCore

/// Renders tokens as `kind:text` so snapshots read naturally.
private func describe(_ line: String, _ tokens: [Token]) -> String {
    let chars = Array(line.utf16)
    return tokens.map { "\($0.kind.rawValue):\(String(decoding: chars[$0.range], as: UTF16.self))" }.joined(separator: " ")
}

private func lex(_ line: String, _ language: Language, _ state: LexState = .normal) -> String {
    describe(line, Lexer.lex(line, language: language, state: state).tokens)
}

/// Lexes consecutive lines carrying the state, returning one description per line.
private func lexLines(_ lines: [String], _ language: Language) -> [String] {
    var state = LexState.normal
    return lines.map { line in
        let result = Lexer.lex(line, language: language, state: state)
        state = result.state
        return describe(line, result.tokens)
    }
}

@Suite struct LanguageDetectionTests {
    @Test func byExtensionAndName() {
        let cases: [(String, Language?)] = [
            ("src/A.cs", .csharp), ("a/b.tsx", .typescript), ("x.ts", .typescript), ("x.jsx", .javascript), ("m.mjs", .javascript),
            ("A.swift", .swift), ("p.json", .json), ("q.sql", .sql), ("s.py", .python), ("run.sh", .shell), ("z.zsh", .shell),
            ("c.yml", .yaml), ("c.yaml", .yaml), ("App.csproj", .xml), ("Dir.props", .xml), ("Dir.targets", .xml), ("V.xaml", .xml),
            ("index.html", .xml), ("Page.razor", .xml), ("a.css", .css), ("a.scss", .css), ("README.md", .markdown),
            ("Dockerfile", .dockerfile), ("docker/Dockerfile.prod", .dockerfile), ("build.ps1", .powershell),
            ("notes.txt", nil), ("Makefile", nil), ("archive.tar.gz", nil),
        ]
        for (path, expected) in cases { #expect(Language.detect(path: path) == expected, "\(path)") }
    }

    @Test func shebangForExtensionlessFiles() {
        #expect(Language.detect(path: "bin/run", firstLine: "#!/bin/bash") == .shell)
        #expect(Language.detect(path: "bin/run", firstLine: "#!/usr/bin/env python3") == .python)
        #expect(Language.detect(path: "bin/run", firstLine: "#!/usr/bin/env node") == .javascript)
        #expect(Language.detect(path: "bin/run", firstLine: "#!/usr/bin/env pwsh") == .powershell)
        #expect(Language.detect(path: "bin/run", firstLine: "echo hi") == nil)
        #expect(Language.detect(path: "run.txt", firstLine: "#!/bin/bash") == nil)   // an extension wins over a shebang
    }
}

@Suite struct LexerSnapshotTests {
    @Test func csharp() {
        #expect(lex("public class LoginService : IService", .csharp) == "keyword:public keyword:class type:LoginService type:IService")
        #expect(lex("var token = Issue(user, 42);", .csharp) == "keyword:var function:Issue number:42")
        #expect(lex("[HttpGet(\"api/x\")]", .csharp) == "attribute:HttpGet string:\"api/x\"")
        #expect(lex("#region Helpers", .csharp) == "preprocessor:#region type:Helpers")
        #expect(lex("var s = $\"hi {name}\"; // done", .csharp) == "keyword:var string:$\"hi {name}\" comment:// done")
        #expect(lex("var p = new Foo(1);", .csharp) == "keyword:var keyword:new type:Foo number:1")
        #expect(lex("this.default = 5", .csharp) == "keyword:this number:5")   // `.default` is a member, not a keyword
        #expect(lex("const int MAX_SIZE = 10;", .csharp) == "keyword:const keyword:int number:10")
    }

    @Test func typescript() {
        #expect(lex("export const total: number = items.length + 0x1F;", .typescript)
            == "keyword:export keyword:const keyword:number number:0x1F")
        #expect(lex("class Foo extends Bar<string> {", .typescript) == "keyword:class type:Foo keyword:extends type:Bar keyword:string")
        #expect(lex("@Component({ selector: 'app' })", .typescript) == "attribute:@Component string:'app'")
        #expect(lex("const f = (x) => foo(x); // c", .typescript) == "keyword:const function:foo comment:// c")
        #expect(lex("let s = 'a\\'b' + \"c\";", .typescript) == "keyword:let string:'a\\'b' string:\"c\"")
    }

    @Test func swift() {
        #expect(lex("@MainActor final class Store: ObservableObject {", .swift)
            == "attribute:@MainActor keyword:final keyword:class type:Store type:ObservableObject")
        #expect(lex("func load(_ path: String) async throws -> Data {", .swift)
            == "keyword:func function:load type:String keyword:async keyword:throws type:Data")
        #expect(lex("#if DEBUG", .swift) == "preprocessor:#if")
        #expect(lex("let n = 3.14 // pi", .swift) == "keyword:let number:3.14 comment:// pi")
        #expect(lex("guard let x = y else { return }", .swift) == "keyword:guard keyword:let keyword:else keyword:return")
    }

    @Test func json() {
        #expect(lex("  \"name\": \"revu\",", .json) == "attribute:\"name\" string:\"revu\"")
        #expect(lex("  \"count\": -12.5e3, \"ok\": true", .json) == "attribute:\"count\" number:12.5e3 attribute:\"ok\" keyword:true")
        #expect(lex("  \"list\": [null]", .json) == "attribute:\"list\" keyword:null")
    }

    @Test func sql() {
        #expect(lex("SELECT TOP 10 Name FROM Users WHERE Id = @id -- who", .sql)
            == "keyword:SELECT keyword:TOP number:10 keyword:FROM keyword:WHERE attribute:@id comment:-- who")
        #expect(lex("insert into [dbo].[T] values ('it''s', 1)", .sql) == "keyword:insert keyword:into keyword:values string:'it''s' number:1")
        #expect(lex("SELECT COUNT(*) FROM t", .sql) == "keyword:SELECT function:COUNT keyword:FROM")
    }

    @Test func python() {
        #expect(lex("def load(path: str) -> dict:  # read", .python) == "keyword:def function:load comment:# read")
        #expect(lex("@dataclass", .python) == "attribute:@dataclass")
        #expect(lex("x = f\"{a}\" + r'\\d+' + 0b101", .python) == "string:f\"{a}\" string:r'\\d+' number:0b101")
        #expect(lex("if x is None and not y:", .python) == "keyword:if keyword:is keyword:None keyword:and keyword:not")
    }

    @Test func shellAndDockerfileAndPowerShell() {
        #expect(lex("if [ -f \"$FILE\" ]; then echo $HOME # note", .shell)
            == "keyword:if string:\"$FILE\" keyword:then keyword:echo attribute:$HOME comment:# note")
        #expect(lex("echo ${#array[@]} 'it'", .shell) == "keyword:echo attribute:${#array[@]} string:'it'")
        #expect(lex("FROM mcr.microsoft.com/dotnet/sdk:8.0 AS build", .dockerfile) == "keyword:FROM number:8.0 keyword:AS")
        #expect(lex("Get-ChildItem -Path $dir | Where-Object { $_ }", .powershell)
            == "function:Get-ChildItem attribute:$dir function:Where-Object attribute:$_")
    }

    @Test func yaml() {
        #expect(lex("name: build   # job", .yaml) == "attribute:name comment:# job")
        #expect(lex("  - image: \"node:20\"", .yaml) == "attribute:image string:\"node:20\"")
        #expect(lex("enabled: true", .yaml) == "attribute:enabled keyword:true")
        #expect(lex("  retries: 3", .yaml) == "attribute:retries number:3")
        #expect(lex("# just a comment", .yaml) == "comment:# just a comment")
        #expect(lex("  - plain item", .yaml) == "")
    }

    @Test func xml() {
        #expect(lex("<Project Sdk=\"Microsoft.NET.Sdk\">", .xml) == "tag:Project attribute:Sdk string:\"Microsoft.NET.Sdk\"")
        #expect(lex("  <PackageReference Include=\"X\" Version=\"1.0\" />", .xml)
            == "tag:PackageReference attribute:Include string:\"X\" attribute:Version string:\"1.0\"")
        #expect(lex("</Project>", .xml) == "tag:Project")
        #expect(lex("<?xml version=\"1.0\"?>", .xml) == "preprocessor:<?xml version=\"1.0\"?>")
        #expect(lex("<!-- note --> <b>text</b>", .xml) == "comment:<!-- note --> tag:b tag:b")
        #expect(lex("<div class='a'>@Model.Name</div>", .xml) == "tag:div attribute:class string:'a' attribute:@Model.Name tag:div")
    }

    @Test func cssAndMarkdown() {
        #expect(lex("  color: #ff0000; /* red */", .css) == "attribute:color number:#ff0000 comment:/* red */")
        #expect(lex("a:hover {", .css) == "")          // a selector, not a property
        #expect(lex("  margin: 10px;", .css) == "attribute:margin number:10px")
        #expect(lex("## Title", .markdown) == "keyword:## Title")
        #expect(lex("- use `code` and **bold** or [link](http://x)", .markdown)
            == "keyword:- string:`code` attribute:**bold** function:[link] string:http://x")
        #expect(lex("> quoted", .markdown) == "comment:> quoted")
    }

    @Test func unknownLanguageHasNoTokens() {
        let diff = makeDiff(" hello world", "+let x = 1")
        #expect(Highlighter.language(for: diff) == nil)   // f.txt
        #expect(Language.detect(path: "x.unknown") == nil)
    }
}

@Suite struct LexerStateTests {
    @Test func blockCommentsSpanLines() {
        let lines = lexLines(["int a; /* start", "still comment", "end */ int b;"], .csharp)
        #expect(lines == ["keyword:int comment:/* start", "comment:still comment", "comment:end */ keyword:int"])
        let css = lexLines(["/* a", "b */ color: red;"], .css)
        #expect(css[0] == "comment:/* a")
        #expect(css[1].hasPrefix("comment:b */"))
    }

    @Test func xmlCommentsAndMultiLineTags() {
        #expect(lexLines(["<!-- a", "b -->", "<x/>"], .xml) == ["comment:<!-- a", "comment:b -->", "tag:x"])
        let tag = lexLines(["<Button", "    Width=\"10\"", "    Text=\"multi", "line\"", "    />", "<Next>"], .xml)
        #expect(tag == ["tag:Button", "attribute:Width string:\"10\"", "attribute:Text string:\"multi", "string:line\"", "", "tag:Next"])
    }

    @Test func csharpVerbatimAndRawStrings() {
        let verbatim = lexLines(["var s = @\"line one", "has \"\"quotes\"\" inside", "end\"; var t = 1;"], .csharp)
        #expect(verbatim == ["keyword:var string:@\"line one", "string:has \"\"quotes\"\" inside", "string:end\" keyword:var number:1"])
        let raw = lexLines(["var s = \"\"\"", "{ \"a\": 1 }", "\"\"\";", "int x;"], .csharp)
        #expect(raw == ["keyword:var string:\"\"\"", "string:{ \"a\": 1 }", "string:\"\"\"", "keyword:int"])
        #expect(lex("var s = \"\"\"inline\"\"\";", .csharp) == "keyword:var string:\"\"\"inline\"\"\"")
    }

    @Test func swiftMultilineStrings() {
        let lines = lexLines(["let s = \"\"\"", "  hello \\\"\"\" still", "  \"\"\"", "let n = 1"], .swift)
        #expect(lines == ["keyword:let string:\"\"\"", "string:  hello \\\"\"\" still", "string:  \"\"\"", "keyword:let number:1"])
    }

    @Test func templateLiteralsAndPythonTripleQuotes() {
        let js = lexLines(["const s = `a", "b ${x}", "c`; run();"], .javascript)
        #expect(js == ["keyword:const string:`a", "string:b ${x}", "string:c` function:run"])
        let py = lexLines(["\"\"\"Docstring", "more", "\"\"\"", "def f(): pass"], .python)
        #expect(py == ["string:\"\"\"Docstring", "string:more", "string:\"\"\"", "keyword:def function:f keyword:pass"])
        #expect(lex("x = '''one line''' + 1", .python) == "string:'''one line''' number:1")
    }

    @Test func markdownFences() {
        let lines = lexLines(["text", "```swift", "let x = 1 // not markdown", "```", "# H"], .markdown)
        #expect(lines == ["", "preprocessor:```swift", "string:let x = 1 // not markdown", "preprocessor:```", "keyword:# H"])
    }

    @Test func statePassedInIsHonoured() {
        let result = Lexer.lex("inside */ x", language: .csharp, state: LexState(mode: .blockComment))
        #expect(result.state == .normal)
        #expect(describe("inside */ x", result.tokens) == "comment:inside */")
    }
}

@Suite struct DiffHighlightTests {
    /// Old file:  /* a        New file:  /* a
    ///            b */                   x
    ///            int y;                 int y;      (the middle lines differ per side)
    @Test func eachSideIsLexedAsItsOwnFile() throws {
        let diff = makeDiff(" /* start", "-old comment line", "+new comment line", " end */", " int y;")
        let h = try #require(Highlighter.highlight(diff: diff, language: .csharp))
        // Both sides are inside the block comment across the changed line.
        #expect(h.tokens(side: .old, diffIndex: 1).map(\.kind) == [.comment])
        #expect(h.tokens(side: .new, diffIndex: 2).map(\.kind) == [.comment])
        #expect(h.tokens(side: .new, diffIndex: 3).map(\.kind) == [.comment])
        #expect(h.tokens(side: .new, diffIndex: 4).map(\.kind) == [.keyword])
        // The new side has no tokens for removed lines and vice versa.
        #expect(h.tokens(side: .new, diffIndex: 1).isEmpty)
        #expect(h.tokens(side: .old, diffIndex: 2).isEmpty)
    }

    @Test func removingTheOpeningOfAMultiLineStringChangesTheOtherSide() throws {
        // Old: `var s = @"a` opens a verbatim string, so the context line `b";` is string on the old side only.
        let diff = makeDiff("-var s = @\"a", "+var s = \"a\";", " b\";")
        let h = try #require(Highlighter.highlight(diff: diff, language: .csharp))
        #expect(h.tokens(side: .old, diffIndex: 2).map(\.range) == [0..<2])    // `b"` closes the verbatim string
        #expect(h.tokens(side: .new, diffIndex: 2).map(\.range) == [1..<3])    // `b` is code, `";` starts a new string
    }

    @Test func tokenRangesAreRelativeToTabExpandedText() throws {
        let diff = makeDiff("+\tvar x = 1;")
        let h = try #require(Highlighter.highlight(diff: diff, language: .csharp))
        let expanded = DisplayText.expandTabs("\tvar x = 1;")
        #expect(expanded == "    var x = 1;")
        let tokens = h.tokens(side: .new, diffIndex: 0)
        #expect(tokens.map(\.range) == [4..<7, 12..<13])        // `var` and `1` at their expanded columns
        #expect(describe(expanded, tokens) == "keyword:var number:1")
    }

    @Test func guardrails() throws {
        let long = String(repeating: "a", count: Highlighter.maxLineLength + 1)
        let diff = makeDiff("+int a; /* open", "+" + long, "+still comment */ int b;")
        let h = try #require(Highlighter.highlight(diff: diff, language: .csharp))
        #expect(h.tokens(side: .new, diffIndex: 1).isEmpty)                           // too long: left plain
        #expect(h.tokens(side: .new, diffIndex: 2).map(\.kind) == [.comment, .keyword])   // state survived it

        let huge = FileDiff(path: "a.cs", lines: (0...Highlighter.maxLines).map {
            DiffLine(kind: .added, oldLine: nil, newLine: $0 + 1, text: "int a;")
        })
        #expect(Highlighter.highlight(diff: huge, language: .csharp) == nil)
    }

    @Test func fiveThousandLinesLexQuickly() throws {
        let spec = (1...5_000).map { "+public void Method\($0)(int x) { var s = \"text\"; } // c" }
        let diff = makeDiff(spec, path: "a.cs")
        let clock = ContinuousClock()
        var h: DiffHighlights?
        let elapsed = clock.measure { h = Highlighter.highlight(diff: diff, language: .csharp) }
        #expect(h?.new.count == 5_000)
        #expect(elapsed < .seconds(2))
    }
}
