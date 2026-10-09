import Foundation

/// A small stateful, dependency-free lexer: `(line, state in) -> (tokens, state out)`.
/// Good enough to colour code in a diff; it makes no attempt to parse.
public enum Lexer {
    public static func lex(_ line: String, language: Language, state: LexState = .normal) -> (tokens: [Token], state: LexState) {
        let chars = Array(line.utf16)
        switch language {
        case .xml: return lexXML(chars, state)
        case .markdown: return lexMarkdown(chars, state)
        default: return lexCode(chars, Spec.for(language), language, state)
        }
    }
}

// MARK: - Character helpers

private func u(_ s: Character) -> UInt16 { s.utf16.first! }
private func isSpace(_ c: UInt16) -> Bool { c == 0x20 || c == 0x09 }
private func isDigit(_ c: UInt16) -> Bool { c >= 0x30 && c <= 0x39 }
private func isLetter(_ c: UInt16) -> Bool { (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c >= 0x80 }
private func isUpper(_ c: UInt16) -> Bool { c >= 0x41 && c <= 0x5A }
private func isLower(_ c: UInt16) -> Bool { c >= 0x61 && c <= 0x7A }
private func isIdentPart(_ c: UInt16) -> Bool { isLetter(c) || isDigit(c) || c == 0x5F }

private func matches(_ chars: [UInt16], _ needle: [UInt16], at i: Int) -> Bool {
    guard i + needle.count <= chars.count else { return false }
    for (k, c) in needle.enumerated() where chars[i + k] != c { return false }
    return true
}

private func find(_ chars: [UInt16], _ needle: [UInt16], from: Int) -> Int? {
    guard !needle.isEmpty, chars.count >= needle.count else { return nil }
    var i = max(from, 0)
    while i + needle.count <= chars.count {
        if matches(chars, needle, at: i) { return i }
        i += 1
    }
    return nil
}

/// End (exclusive) of a quoted string starting at `start` (the opening quote). Unterminated: end of line.
private func scanQuoted(_ chars: [UInt16], from start: Int, quote: UInt16, escape: UInt16?, doubled: Bool) -> Int {
    var i = start + 1
    while i < chars.count {
        let c = chars[i]
        if let escape, c == escape { i += 2; continue }
        if c == quote {
            if doubled, i + 1 < chars.count, chars[i + 1] == quote { i += 2; continue }
            return i + 1
        }
        i += 1
    }
    return chars.count
}

// MARK: - Language specs

private struct Spec {
    var keywords: Set<String> = []
    var ignoreCase = false
    var lineComments: [[UInt16]] = []
    var blockComment: (open: [UInt16], close: [UInt16])?
    var quotes: [UInt16] = [u("\""), u("'")]
    var escape: UInt16? = u("\\")
    var doubledQuote = false
    var pascalTypes = false
    var calls = true
    var atAttribute = false
    var dollarVariable = false
    /// `#if`-style directives: only as the first thing on a line (C#) or anywhere (Swift).
    var directives: Directives = .none
    var csharp = false
    var swift = false
    var python = false
    var javascript = false
    var json = false
    var yaml = false
    var css = false
    var powershell = false
    var shell = false

    enum Directives { case none, lineStart, anywhere }

    static func words(_ s: String) -> Set<String> { Set(s.split(separator: " ").map(String.init)) }

    static func `for`(_ language: Language) -> Spec {
        var spec = Spec()
        let slashes: [[UInt16]] = [[u("/"), u("/")]]
        let block = (open: [u("/"), u("*")], close: [u("*"), u("/")])
        switch language {
        case .csharp:
            spec.keywords = words("""
                abstract as base bool break byte case catch char checked class const continue decimal default delegate do double \
                else enum event explicit extern false finally fixed float for foreach goto if implicit in int interface internal \
                is lock long namespace new null object operator out override params private protected public readonly ref return \
                sbyte sealed short sizeof stackalloc static string struct switch this throw true try typeof uint ulong unchecked \
                unsafe ushort using virtual void volatile while var async await record init get set yield partial where when with \
                required file nameof dynamic global add remove and or not
                """)
            spec.lineComments = slashes; spec.blockComment = block; spec.pascalTypes = true
            spec.directives = .lineStart; spec.csharp = true
        case .typescript, .javascript:
            spec.keywords = words("""
                break case catch class const continue debugger default delete do else enum export extends false finally for \
                function if import in instanceof new null return super switch this throw true try typeof var void while with yield \
                let static async await of from as undefined number string boolean any never unknown object symbol bigint \
                constructor
                """)
            if language == .typescript {
                spec.keywords.formUnion(Spec.words("type interface implements private protected public readonly abstract declare namespace module keyof satisfies infer is override get set"))
            }
            spec.quotes = [u("\""), u("'")]
            spec.lineComments = slashes; spec.blockComment = block; spec.pascalTypes = language == .typescript
            spec.atAttribute = true; spec.javascript = true
        case .swift:
            spec.keywords = words("""
                associatedtype class deinit enum extension fileprivate func import init inout internal let open operator private \
                precedencegroup protocol public rethrows static struct subscript typealias var break case catch continue default \
                defer do else fallthrough for guard if in repeat return throw switch where while Any as await false is nil self \
                Self super throws true try async actor some any final lazy mutating nonmutating override required convenience \
                weak unowned indirect dynamic get set willSet didSet macro
                """)
            spec.quotes = [u("\"")]
            spec.lineComments = slashes; spec.blockComment = block; spec.pascalTypes = true
            spec.atAttribute = true; spec.directives = .anywhere; spec.swift = true
        case .json:
            spec.keywords = words("true false null")
            spec.quotes = [u("\"")]; spec.calls = false; spec.json = true
            spec.lineComments = slashes; spec.blockComment = block
        case .sql:
            spec.keywords = words("""
                select from where and or not in is null like between join inner left right outer full cross on group by order \
                having insert into values update set delete create alter drop table index view procedure proc function trigger \
                database schema begin end if else while return declare exec execute as distinct top union all case when then \
                primary key foreign references constraint default identity unique check with nolock go use print throw try catch \
                commit rollback transaction int bigint smallint tinyint varchar nvarchar char nchar bit datetime datetime2 date \
                time decimal numeric float real money uniqueidentifier text exists asc desc limit offset over partition add column \
                rename to truncate grant revoke output returns for each row
                """)
            spec.ignoreCase = true; spec.quotes = [u("'")]; spec.escape = nil; spec.doubledQuote = true
            spec.lineComments = [[u("-"), u("-")]]; spec.blockComment = block; spec.atAttribute = true
        case .python:
            spec.keywords = words("""
                and as assert async await break class continue def del elif else except False finally for from global if import \
                in is lambda None nonlocal not or pass raise return True try while with yield match case
                """)
            spec.lineComments = [[u("#")]]; spec.atAttribute = true; spec.python = true
        case .shell:
            spec.keywords = words("""
                if then else elif fi for while until do done case esac in function select time return exit export local readonly \
                declare unset set shift source alias echo cd test eval exec trap
                """)
            spec.lineComments = [[u("#")]]; spec.dollarVariable = true; spec.calls = false; spec.shell = true
            spec.quotes = [u("\""), u("'"), u("`")]
        case .yaml:
            spec.keywords = words("true false null yes no on off True False Null ~")
            spec.lineComments = [[u("#")]]; spec.calls = false; spec.yaml = true; spec.doubledQuote = false
        case .css:
            spec.lineComments = slashes; spec.blockComment = block; spec.calls = true; spec.css = true
            spec.keywords = words("important")
        case .dockerfile:
            spec.keywords = words("FROM RUN CMD LABEL EXPOSE ENV ADD COPY ENTRYPOINT VOLUME USER WORKDIR ARG ONBUILD STOPSIGNAL HEALTHCHECK SHELL AS MAINTAINER")
            spec.lineComments = [[u("#")]]; spec.dollarVariable = true; spec.calls = false
        case .powershell:
            spec.keywords = words("""
                function param begin process end if elseif else switch foreach for while do until break continue return throw try \
                catch finally in class using namespace exit filter trap workflow
                """)
            spec.ignoreCase = true
            spec.lineComments = [[u("#")]]; spec.blockComment = (open: [u("<"), u("#")], close: [u("#"), u(">")])
            spec.dollarVariable = true; spec.escape = u("`"); spec.powershell = true; spec.calls = false
        case .xml, .markdown:
            break
        }
        return spec
    }
}

// MARK: - Generic code lexer

private func lexCode(_ chars: [UInt16], _ spec: Spec, _ language: Language, _ startState: LexState) -> ([Token], LexState) {
    var tokens: [Token] = []
    var state = startState
    var i = 0
    let n = chars.count
    func add(_ s: Int, _ e: Int, _ kind: TokenKind) { if e > s { tokens.append(Token(s..<e, kind)) } }

    // Resume a construct that started on an earlier line.
    switch state.mode {
    case .normal, .xmlComment, .xmlTag, .xmlQuote, .fence:
        break
    case .blockComment:
        let close = spec.blockComment?.close ?? []
        guard let end = find(chars, close, from: 0) else { add(0, n, .comment); return (tokens, state) }
        add(0, end + close.count, .comment); i = end + close.count; state = .normal
    case .verbatimString:
        guard let end = closingQuote(chars, from: 0, quote: u("\""), doubled: true) else { add(0, n, .string); return (tokens, state) }
        add(0, end, .string); i = end; state = .normal
    case let .rawString(count):
        let close = [UInt16](repeating: u("\""), count: count)
        guard let end = find(chars, close, from: 0) else { add(0, n, .string); return (tokens, state) }
        var stop = end + count
        while stop < n, chars[stop] == u("\"") { stop += 1 }
        add(0, stop, .string); i = stop; state = .normal
    case .multilineString:
        var k = 0
        var end: Int?
        while k < n {
            if chars[k] == u("\\") { k += 2; continue }
            if matches(chars, [u("\""), u("\""), u("\"")], at: k) { end = k + 3; break }
            k += 1
        }
        guard let end else { add(0, n, .string); return (tokens, state) }
        add(0, end, .string); i = end; state = .normal
    case .template:
        var k = 0
        var end: Int?
        while k < n {
            if chars[k] == u("\\") { k += 2; continue }
            if chars[k] == u("`") { end = k + 1; break }
            k += 1
        }
        guard let end else { add(0, n, .string); return (tokens, state) }
        add(0, end, .string); i = end; state = .normal
    case let .tripleQuote(q):
        var k = 0
        var end: Int?
        while k < n {
            if chars[k] == u("\\") { k += 2; continue }
            if matches(chars, [q, q, q], at: k) { end = k + 3; break }
            k += 1
        }
        guard let end else { add(0, n, .string); return (tokens, state) }
        add(0, end, .string); i = end; state = .normal
    }

    var firstNonSpace = 0
    while firstNonSpace < n, isSpace(chars[firstNonSpace]) { firstNonSpace += 1 }
    var expectAttributeName = false
    var previousWord = ""

    if spec.yaml, i == 0, let key = yamlKeyRange(chars) {
        add(key.lowerBound, key.upperBound, .attribute)
        i = key.upperBound
    }
    if spec.css, i == 0, let prop = cssPropertyRange(chars) {
        add(prop.lowerBound, prop.upperBound, .attribute)
        i = prop.upperBound
    }

    mainLoop: while i < n {
        let c = chars[i]
        if isSpace(c) { i += 1; continue }
        let atBoundary = i == 0 || isSpace(chars[i - 1]) || chars[i - 1] == u(";")

        for comment in spec.lineComments where matches(chars, comment, at: i) {
            if comment == [u("#")] && !atBoundary { continue }
            add(i, n, .comment)
            return (tokens, state)
        }
        if let block = spec.blockComment, matches(chars, block.open, at: i) {
            if let end = find(chars, block.close, from: i + block.open.count) {
                add(i, end + block.close.count, .comment); i = end + block.close.count
                continue
            }
            add(i, n, .comment)
            return (tokens, LexState(mode: .blockComment))
        }

        // Directives: #region, #if, #available ...
        if c == u("#"), spec.directives != .none, i + 1 < n, isLetter(chars[i + 1]),
           spec.directives == .anywhere || i == firstNonSpace {
            var e = i + 1
            while e < n, isIdentPart(chars[e]) { e += 1 }
            add(i, e, .preprocessor); i = e
            continue
        }

        // C# string prefixes: $"..." @"..." $@"..." and raw """...""".
        if spec.csharp, c == u("$") || c == u("@") || c == u("\"") {
            var p = 0
            var verbatim = false
            while i + p < n, chars[i + p] == u("$") || chars[i + p] == u("@") {
                if chars[i + p] == u("@") { verbatim = true }
                p += 1
            }
            if i + p < n, chars[i + p] == u("\"") {
                var quotes = 0
                while i + p + quotes < n, chars[i + p + quotes] == u("\"") { quotes += 1 }
                if quotes >= 3 {
                    let close = [UInt16](repeating: u("\""), count: quotes)
                    if let end = find(chars, close, from: i + p + quotes) {
                        var stop = end + quotes
                        while stop < n, chars[stop] == u("\"") { stop += 1 }
                        add(i, stop, .string); i = stop; continue
                    }
                    add(i, n, .string)
                    return (tokens, LexState(mode: .rawString(quotes)))
                }
                if verbatim {
                    guard let end = closingQuote(chars, from: i + p + 1, quote: u("\""), doubled: true) else {
                        add(i, n, .string)
                        return (tokens, LexState(mode: .verbatimString))
                    }
                    add(i, end, .string); i = end; continue
                }
                let end = scanQuoted(chars, from: i + p, quote: u("\""), escape: u("\\"), doubled: false)
                add(i, end, .string); i = end; continue
            }
        }

        // Quoted strings.
        if spec.quotes.contains(c) {
            if spec.swift, c == u("\""), matches(chars, [c, c, c], at: i) {
                var k = i + 3
                while k < n {
                    if chars[k] == u("\\") { k += 2; continue }
                    if matches(chars, [c, c, c], at: k) { break }
                    k += 1
                }
                if k < n { add(i, k + 3, .string); i = k + 3; continue }
                add(i, n, .string)
                return (tokens, LexState(mode: .multilineString))
            }
            if spec.python, matches(chars, [c, c, c], at: i) {
                if let end = findTriple(chars, quote: c, from: i + 3) { add(i, end, .string); i = end; continue }
                add(i, n, .string)
                return (tokens, LexState(mode: .tripleQuote(c)))
            }
            // Shell single quotes have no escapes.
            let escape = (spec.shell && c == u("'")) ? nil : spec.escape
            let end = scanQuoted(chars, from: i, quote: c, escape: escape, doubled: spec.doubledQuote || (spec.powershell || spec.yaml) && c == u("'"))
            if spec.json, isKey(chars, after: end) { add(i, end, .attribute) } else { add(i, end, .string) }
            i = end
            continue
        }
        if spec.javascript, c == u("`") {
            var k = i + 1
            while k < n {
                if chars[k] == u("\\") { k += 2; continue }
                if chars[k] == u("`") { break }
                k += 1
            }
            if k < n { add(i, k + 1, .string); i = k + 1; continue }
            add(i, n, .string)
            return (tokens, LexState(mode: .template))
        }

        // Numbers (also CSS hex colours).
        if isDigit(c) || (c == u(".") && i + 1 < n && isDigit(chars[i + 1]) && (i == 0 || !isIdentPart(chars[i - 1]))) || (spec.css && c == u("#") && hexRun(chars, i + 1) >= 3) {
            var e = i + 1
            while e < n {
                let d = chars[e]
                if isIdentPart(d) || (spec.css && d == u("%")) { e += 1 }
                else if d == u("."), e + 1 < n, isDigit(chars[e + 1]) { e += 1 }
                else { break }
            }
            add(i, e, .number); i = e
            continue
        }

        // Attributes / decorators / variables.
        if c == u("@"), spec.atAttribute || spec.css, i + 1 < n, isLetter(chars[i + 1]) {
            var e = i + 1
            while e < n, isIdentPart(chars[e]) { e += 1 }
            add(i, e, .attribute); i = e
            continue
        }
        if (c == u("$") && spec.dollarVariable) || (c == u("$") && spec.css), i + 1 < n, isLetter(chars[i + 1]) || chars[i + 1] == u("{") || chars[i + 1] == u("(") || chars[i + 1] == u("_") {
            var e = i + 1
            if chars[e] == u("{") || chars[e] == u("(") {
                let closing = chars[e] == u("{") ? u("}") : u(")")
                while e < n, chars[e] != closing { e += 1 }
                e = min(e + 1, n)
            } else {
                while e < n, isIdentPart(chars[e]) { e += 1 }
            }
            add(i, e, .attribute); i = e
            continue
        }
        if c == u("["), spec.csharp, i == firstNonSpace { expectAttributeName = true; i += 1; continue }

        // Identifiers and keywords.
        if isLetter(c) || c == u("_") || (c == u("$") && spec.javascript) || (c == u("-") && spec.css && i + 1 < n && chars[i + 1] == u("-")) {
            var e = i + 1
            while e < n {
                let d = chars[e]
                if isIdentPart(d) || (d == u("$") && spec.javascript) { e += 1 }
                else if d == u("-"), spec.powershell || spec.css, e + 1 < n, isLetter(chars[e + 1]) { e += 1 }
                else { break }
            }
            let word = String(decoding: chars[i..<e], as: UTF16.self)

            // Python string prefixes (r"...", f'...').
            if spec.python, e < n, chars[e] == u("\"") || chars[e] == u("'"), word.count <= 2,
               word.lowercased().allSatisfy({ "rbfu".contains($0) }) {
                let q = chars[e]
                if matches(chars, [q, q, q], at: e) {
                    if let end = findTriple(chars, quote: q, from: e + 3) { add(i, end, .string); i = end; continue }
                    add(i, n, .string)
                    return (tokens, LexState(mode: .tripleQuote(q)))
                }
                let end = scanQuoted(chars, from: e, quote: q, escape: spec.escape, doubled: false)
                add(i, end, .string); i = end
                continue
            }

            let afterDot = previousNonSpace(chars, before: i) == u(".")
            var next = e
            while next < n, isSpace(chars[next]) { next += 1 }
            let isCall = spec.calls && next < n && chars[next] == u("(")
            let isKeyword = !afterDot && spec.keywords.contains(spec.ignoreCase ? word.lowercased() : word)

            if expectAttributeName {
                add(i, e, .attribute); expectAttributeName = false
            } else if isKeyword {
                add(i, e, .keyword)
            } else if spec.pascalTypes, isPascalCase(chars[i..<e]), previousWord == "new" || !isCall {
                add(i, e, .type)
            } else if isCall {
                add(i, e, .function)
            } else if spec.powershell, word.contains("-"), isUpper(chars[i]) {
                add(i, e, .function)
            }
            previousWord = word
            i = e
            continue
        }
        i += 1
    }
    return (tokens, state)
}

/// Index just past the closing `quote` found at or after `from` (no escapes; `doubled` makes `""` an escaped quote).
private func closingQuote(_ chars: [UInt16], from: Int, quote: UInt16, doubled: Bool) -> Int? {
    var i = from
    while i < chars.count {
        if chars[i] == quote {
            if doubled, i + 1 < chars.count, chars[i + 1] == quote { i += 2; continue }
            return i + 1
        }
        i += 1
    }
    return nil
}

private func findTriple(_ chars: [UInt16], quote: UInt16, from: Int) -> Int? {
    var k = from
    while k < chars.count {
        if chars[k] == u("\\") { k += 2; continue }
        if matches(chars, [quote, quote, quote], at: k) { return k + 3 }
        k += 1
    }
    return nil
}

private func previousNonSpace(_ chars: [UInt16], before i: Int) -> UInt16? {
    var k = i - 1
    while k >= 0, isSpace(chars[k]) { k -= 1 }
    return k >= 0 ? chars[k] : nil
}

private func hexRun(_ chars: [UInt16], _ from: Int) -> Int {
    var k = from
    while k < chars.count, isDigit(chars[k]) || (chars[k] >= 0x41 && chars[k] <= 0x46) || (chars[k] >= 0x61 && chars[k] <= 0x66) { k += 1 }
    return k - from
}

/// PascalCase: starts upper-case and has a lower-case letter (so `URL` and `MAX_SIZE` stay plain).
private func isPascalCase(_ word: ArraySlice<UInt16>) -> Bool {
    guard let first = word.first, isUpper(first) else { return false }
    return word.contains(where: isLower)
}

/// True if the next non-space character after `end` is a colon (a JSON object key).
private func isKey(_ chars: [UInt16], after end: Int) -> Bool {
    var k = end
    while k < chars.count, isSpace(chars[k]) { k += 1 }
    return k < chars.count && chars[k] == u(":")
}

/// `key:` at the start of a YAML line (optionally after `- `): returns the key's range.
private func yamlKeyRange(_ chars: [UInt16]) -> Range<Int>? {
    var i = 0
    while i < chars.count, isSpace(chars[i]) || chars[i] == u("-") && i + 1 < chars.count && isSpace(chars[i + 1]) { i += 1 }
    let start = i
    guard start < chars.count, chars[start] != u("#"), chars[start] != u("\""), chars[start] != u("'") else { return nil }
    while i < chars.count {
        if chars[i] == u(":") && (i + 1 == chars.count || isSpace(chars[i + 1])) { return i > start ? start..<i : nil }
        if chars[i] == u("#") && i > 0 && isSpace(chars[i - 1]) { return nil }
        i += 1
    }
    return nil
}

/// A CSS declaration name (`color:` followed by a space or end of line), as opposed to `a:hover`.
private func cssPropertyRange(_ chars: [UInt16]) -> Range<Int>? {
    var i = 0
    while i < chars.count, isSpace(chars[i]) { i += 1 }
    let start = i
    while i < chars.count, isIdentPart(chars[i]) || chars[i] == u("-") { i += 1 }
    guard i > start, i < chars.count, chars[i] == u(":"), i + 1 == chars.count || isSpace(chars[i + 1]) else { return nil }
    return start..<i
}

// MARK: - XML / HTML

private func lexXML(_ chars: [UInt16], _ startState: LexState) -> ([Token], LexState) {
    var tokens: [Token] = []
    var state = startState
    let n = chars.count
    var i = 0
    func add(_ s: Int, _ e: Int, _ kind: TokenKind) { if e > s { tokens.append(Token(s..<e, kind)) } }

    switch state.mode {
    case .xmlComment:
        guard let end = find(chars, [u("-"), u("-"), u(">")], from: 0) else { add(0, n, .comment); return (tokens, state) }
        add(0, end + 3, .comment); i = end + 3; state = .normal
    case let .xmlQuote(q):
        guard let end = closingQuote(chars, from: 0, quote: q, doubled: false) else { add(0, n, .string); return (tokens, state) }
        add(0, end, .string); i = end; state = LexState(mode: .xmlTag)
    default:
        break
    }

    while i < n {
        if state.mode == .xmlTag {
            let c = chars[i]
            if isSpace(c) { i += 1; continue }
            if c == u(">") { i += 1; state = .normal; continue }
            if c == u("/"), i + 1 < n, chars[i + 1] == u(">") { i += 2; state = .normal; continue }
            if c == u("\"") || c == u("'") {
                guard let end = closingQuote(chars, from: i + 1, quote: c, doubled: false) else {
                    add(i, n, .string)
                    return (tokens, LexState(mode: .xmlQuote(c)))
                }
                add(i, end, .string); i = end; continue
            }
            if isLetter(c) || c == u("_") || c == u(":") || c == u("@") {
                var e = i + 1
                while e < n, isIdentPart(chars[e]) || chars[e] == u("-") || chars[e] == u(":") || chars[e] == u(".") { e += 1 }
                add(i, e, .attribute); i = e; continue
            }
            i += 1
            continue
        }

        // Text content.
        let c = chars[i]
        if c == u("<") {
            if matches(chars, [u("<"), u("!"), u("-"), u("-")], at: i) {
                if let end = find(chars, [u("-"), u("-"), u(">")], from: i + 4) { add(i, end + 3, .comment); i = end + 3; continue }
                add(i, n, .comment)
                return (tokens, LexState(mode: .xmlComment))
            }
            if i + 1 < n, chars[i + 1] == u("?") || chars[i + 1] == u("!") {
                let terminator: [UInt16] = chars[i + 1] == u("?") ? [u("?"), u(">")] : [u(">")]
                let end = find(chars, terminator, from: i + 2).map { $0 + terminator.count } ?? n
                add(i, end, .preprocessor); i = end; continue
            }
            var e = i + 1
            if e < n, chars[e] == u("/") { e += 1 }
            let nameStart = e
            while e < n, isIdentPart(chars[e]) || chars[e] == u("-") || chars[e] == u(":") || chars[e] == u(".") { e += 1 }
            if e > nameStart {
                add(nameStart, e, .tag); i = e
                state = LexState(mode: .xmlTag)
                continue
            }
        }
        if c == u("@"), i + 1 < n, isLetter(chars[i + 1]) {   // Razor: @Model.Name, @code
            var e = i + 1
            while e < n, isIdentPart(chars[e]) || chars[e] == u(".") { e += 1 }
            add(i, e, .attribute); i = e; continue
        }
        i += 1
    }
    return (tokens, state)
}

// MARK: - Markdown (light touch)

private func lexMarkdown(_ chars: [UInt16], _ startState: LexState) -> ([Token], LexState) {
    let n = chars.count
    var tokens: [Token] = []
    func add(_ s: Int, _ e: Int, _ kind: TokenKind) { if e > s { tokens.append(Token(s..<e, kind)) } }

    var start = 0
    while start < n, isSpace(chars[start]) { start += 1 }
    let isFence = matches(chars, [u("`"), u("`"), u("`")], at: start) || matches(chars, [u("~"), u("~"), u("~")], at: start)
    if isFence {
        add(0, n, .preprocessor)
        return (tokens, startState.mode == .fence ? .normal : LexState(mode: .fence))
    }
    if startState.mode == .fence {
        add(0, n, .string)
        return (tokens, startState)
    }
    // Headings.
    var hashes = 0
    while start + hashes < n, chars[start + hashes] == u("#") { hashes += 1 }
    if hashes > 0, hashes <= 6, start == 0, start + hashes < n, isSpace(chars[start + hashes]) {
        add(0, n, .keyword)
        return (tokens, .normal)
    }
    if start < n, chars[start] == u(">") { add(0, n, .comment); return (tokens, .normal) }

    var i = start
    // List markers.
    if i < n, chars[i] == u("-") || chars[i] == u("*") || chars[i] == u("+"), i + 1 < n, isSpace(chars[i + 1]) {
        add(i, i + 1, .keyword); i += 2
    } else {
        var e = i
        while e < n, isDigit(chars[e]) { e += 1 }
        if e > i, e + 1 < n, chars[e] == u("."), isSpace(chars[e + 1]) { add(i, e + 1, .keyword); i = e + 2 }
    }

    while i < n {
        let c = chars[i]
        if c == u("`") {
            if let end = find(chars, [u("`")], from: i + 1) { add(i, end + 1, .string); i = end + 1; continue }
        } else if c == u("*") || c == u("_") {
            let run = (i + 1 < n && chars[i + 1] == c) ? 2 : 1
            let marker = [UInt16](repeating: c, count: run)
            if i + run < n, !isSpace(chars[i + run]), (i == 0 || !isIdentPart(chars[i - 1])),
               let end = find(chars, marker, from: i + run), end > i + run, !isSpace(chars[end - 1]) {
                add(i, end + run, .attribute); i = end + run; continue
            }
        } else if c == u("[") {
            if let close = find(chars, [u("]"), u("(")], from: i + 1), let paren = find(chars, [u(")")], from: close + 2) {
                add(i, close + 1, .function)
                add(close + 2, paren, .string)
                i = paren + 1
                continue
            }
        }
        i += 1
    }
    return (tokens, .normal)
}
