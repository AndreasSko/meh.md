import Foundation
import XCTest

@testable import NoteCore

final class JinjaTemplateTests: XCTestCase {
    private let context = JinjaTemplate.Context(timeZone: TimeZone(identifier: "Europe/Berlin")!)

    private func render(_ source: String, _ values: [String: JinjaValue] = [:]) throws -> String {
        try JinjaTemplate(source).render(values, context: context)
    }

    func testVariablesAndFilters() throws {
        XCTAssertEqual(try render("Hi {{ name }}!", ["name": .string("Ada")]), "Hi Ada!")
        XCTAssertEqual(try render("{{ name | trim | upper }}", ["name": .string(" ada ")]), "ADA")
        XCTAssertEqual(try render("{{ missing | default('none') }}"), "none")
        XCTAssertEqual(try render("{{ tags | join(', ') }}", ["tags": .list([.string("a"), .string("b")])]), "a, b")
        XCTAssertEqual(try render("{{ text | blockquote }}", ["text": .string("one\n\ntwo")]), "> one\n>\n> two")
        XCTAssertEqual(try render("{{ a | yaml }} {{ b | yaml }}", ["a": .string("Plain name"), "b": .string("x: y")]),
                       "Plain name \"x: y\"")
        XCTAssertEqual(try render("{{ author.split(' ') | last }}", ["author": .string("Ada Lovelace")]), "Lovelace")
    }

    func testConditionsLoopsAndSet() throws {
        let source = """
            {% set name = author|trim %}{% if name == "Ada" %}A{% elif name %}B{% else %}C{% endif %}\
            {% for tag in tags %}[{{ tag }}]{% endfor %}{{ " 📚" if category == "books" }}
            """
        XCTAssertEqual(try render(source, ["author": .string(" Ada "), "tags": .list([.string("x")]),
                                           "category": .string("books")]), "A[x] 📚")
        XCTAssertEqual(try render(source, ["author": .string("Bo"), "tags": .list([]), "category": .string("x")]), "B")
        XCTAssertEqual(try render(source), "C")
    }

    func testWhitespaceControlAndComments() throws {
        XCTAssertEqual(try render("a  {%- if true -%}  b  {%- endif %} {# note #}c"), "ab c")
    }

    func testDatesUseReadwiseLetters() throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(try render("{{ d | date('F j, Y H:i') }}", ["d": .date(date)]), "January 15, 2027 09:00")
    }

    func testErrorsNameTheLine() throws {
        XCTAssertThrowsError(try JinjaTemplate("one\n{% if x %}two")) { error in
            XCTAssertEqual((error as? JinjaTemplateError)?.line, 2)
        }
        XCTAssertThrowsError(try JinjaTemplate("{{ x | nope }}"))
        XCTAssertThrowsError(try JinjaTemplate("{{ x "))
    }

    func testStringEscapesAndBracesInQuotes() throws {
        XCTAssertEqual(try render("{{ tags | join('\\n') }}", ["tags": .list([.string("a"), .string("b")])]), "a\nb")
        XCTAssertEqual(try render("{{ '}}' }}"), "}}")
        XCTAssertEqual(try render("{{ 'it\\'s' }}"), "it's")
    }

    func testLoneBracesStayText() throws {
        XCTAssertEqual(try render("a { b } c"), "a { b } c")
    }
}
