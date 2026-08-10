//
//  CaveatFormatTests.swift
//  BreweryTests
//

import Testing
@testable import Brewery

@Suite("Caveat formatting")
struct CaveatFormatTests {

    @Test("the python@3.10 shape: prose and indented runs alternate, indent stripped")
    func pythonShape() {
        let text = """
        Python is installed as
          /opt/homebrew/bin/python3.10

        You can install Python packages with
          pip3.10 install <package>
        They will install into the site-package directory
          /opt/homebrew/lib/python3.10/site-packages
        """
        #expect(CaveatFormat.blocks(of: text) == [
            .text("Python is installed as"),
            .code("/opt/homebrew/bin/python3.10"),
            .text("You can install Python packages with"),
            .code("pip3.10 install <package>"),   // verbatim — no markdown eats the <angle brackets>
            .text("They will install into the site-package directory"),
            .code("/opt/homebrew/lib/python3.10/site-packages"),
        ])
    }

    @Test("multi-line command runs stay one block; backticks in prose stay for the renderer")
    func grouping() {
        let text = """
        To restart `foo` run:
          brew services stop foo
          brew services start foo
        """
        #expect(CaveatFormat.blocks(of: text) == [
            .text("To restart `foo` run:"),
            .code("brew services stop foo\nbrew services start foo"),
        ])
    }

    @Test("all-prose, all-code, tabs, and trailing blank lines")
    func edges() {
        #expect(CaveatFormat.blocks(of: "Just a sentence.") == [.text("Just a sentence.")])
        #expect(CaveatFormat.blocks(of: "\tmake install\n") == [.code("make install")])
        #expect(CaveatFormat.blocks(of: "A\nB\n\n\nC\n\n") == [.text("A\nB"), .text("C")])
        #expect(CaveatFormat.blocks(of: "") == [])
    }
}
