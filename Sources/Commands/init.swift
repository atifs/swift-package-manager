/*
 This source file is part of the Swift.org open source project

 Copyright 2015 - 2016 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import Basic
import PackageModel
import POSIX

import func Utility.fopen
import func Utility.fputs
import func Utility.makeDirectories
import struct Utility.Path

private extension FSProxy {
    /// Write to a file from a stream producer.
    mutating func writeFileContents(_ path: String, body: @noescape (OutputByteStream) -> ()) throws {
        let contents = OutputByteStream()
        body(contents)
        try createDirectory(path.parentDirectory, recursive: true)
        try writeFileContents(path, bytes: contents.bytes)
    }
}

private enum InitError: ErrorProtocol {
    case manifestAlreadyExists
}

extension InitError: CustomStringConvertible {
    var description: String {
        switch self {
        case .manifestAlreadyExists:
            return "a manifest file already exists in this directory"
        }
    }
}

/// Create an initial template package.
final class InitPackage {
    let rootd = POSIX.getcwd()

    /// The mode in use.
    let mode: InitMode

    /// The name of the example package to create.
    let pkgname: String

    /// The name of the example module to create.
    var moduleName: String {
        return pkgname
    }

    /// The name of the example type to create (within the package).
    var typeName: String {
        return pkgname
    }
    
    init(mode: InitMode) throws {
        // Validate that the name is valid.
        let _ = try c99name(name: rootd.basename)
        
        self.mode = mode
        pkgname = rootd.basename
    }
    
    func writePackageStructure() throws {
        print("Creating \(mode) package: \(pkgname)")

        // FIXME: We should form everything we want to write, then validate that
        // none of it exists, and then act.
        try writeManifestFile()
        try writeGitIgnore()
        try writeSources()
        try writeModuleMap()
        try writeTests()
    }

    private func writePackageFile(_ path: String, body: @noescape (OutputByteStream) -> ()) throws {
        print("Creating \(Path(path).relative(to: rootd))")
        try localFS.writeFileContents(path, body: body)
    }
    
    private func writeManifestFile() throws {
        let manifest = Path.join(rootd, Manifest.filename)
        guard manifest.exists == false else {
            throw InitError.manifestAlreadyExists
        }

        try writePackageFile(manifest) { stream in
            stream <<< "import PackageDescription\n"
            stream <<< "\n"
            stream <<< "let package = Package(\n"
            stream <<< "    name: \"\(pkgname)\"\n"
            stream <<< ")\n"
        }
    }
    
    private func writeGitIgnore() throws {
        let gitignore = Path.join(rootd, ".gitignore")
        guard gitignore.exists == false else {
            return
        } 
        let gitignoreFP = try Utility.fopen(gitignore, mode: .write)
        defer { gitignoreFP.closeFile() }
    
        try writePackageFile(gitignore) { stream in
            stream <<< ".DS_Store\n"
            stream <<< "/.build\n"
            stream <<< "/Packages\n"
            stream <<< "/*.xcodeproj\n"
        }
    }
    
    private func writeSources() throws {
        if mode == .systemModule {
            return
        }
        let sources = Path.join(rootd, "Sources")
        guard sources.exists == false else {
            return
        }
        print("Creating Sources/")
        try Utility.makeDirectories(sources)
    
        let sourceFileName = (mode == .executable) ? "main.swift" : "\(typeName).swift"
        let sourceFile = Path.join(sources, sourceFileName)

        try writePackageFile(sourceFile) { stream in
            switch mode {
            case .library:
                stream <<< "struct \(typeName) {\n\n"
                stream <<< "    var text = \"Hello, World!\"\n"
                stream <<< "}\n"
            case .executable:
                stream <<< "print(\"Hello, world!\")\n"
            case .systemModule:
                break
            }
        }
    }
    
    private func writeModuleMap() throws {
        if mode != .systemModule {
            return
        }
        let modulemap = Path.join(rootd, "module.modulemap")
        guard modulemap.exists == false else {
            return
        }
        
        try writePackageFile(modulemap) { stream in
            stream <<< "module \(moduleName) [system] {\n"
            stream <<< "  header \"/usr/include/\(moduleName).h\"\n"
            stream <<< "  link \"\(moduleName)\"\n"
            stream <<< "  export *\n"
            stream <<< "}\n"
        }
    }
    
    private func writeTests() throws {
        if mode == .systemModule {
            return
        }
        let tests = Path.join(rootd, "Tests")
        guard tests.exists == false else {
            return
        }
        print("Creating Tests/")
        try Utility.makeDirectories(tests)

        // Only libraries are testable for now.
        if mode == .library {
            try writeLinuxMain(testsPath: tests)
            try writeTestFileStubs(testsPath: tests)
        }
    }
    
    private func writeLinuxMain(testsPath: String) throws {
        try writePackageFile(Path.join(testsPath, "LinuxMain.swift")) { stream in
            stream <<< "import XCTest\n"
            stream <<< "@testable import \(moduleName)TestSuite\n\n"
            stream <<< "XCTMain([\n"
            stream <<< "     testCase(\(typeName)Tests.allTests),\n"
            stream <<< "])\n"
        }
    }
    
    private func writeTestFileStubs(testsPath: String) throws {
        let testModule = Path.join(testsPath, moduleName)
        print("Creating Tests/\(moduleName)/")
        try Utility.makeDirectories(testModule)
        
        try writePackageFile(Path.join(testModule, "\(moduleName)Tests.swift")) { stream in
            stream <<< "import XCTest\n"
            stream <<< "@testable import \(moduleName)\n"
            stream <<< "\n"
            stream <<< "class \(moduleName)Tests: XCTestCase {\n"
            stream <<< "    func testExample() {\n"
            stream <<< "        // This is an example of a functional test case.\n"
            stream <<< "        // Use XCTAssert and related functions to verify your tests produce the correct results.\n"
            stream <<< "        XCTAssertEqual(\(typeName)().text, \"Hello, World!\")\n"
            stream <<< "    }\n"
            stream <<< "\n"
            stream <<< "\n"
            stream <<< "    static var allTests : [(String, (\(moduleName)Tests) -> () throws -> Void)] {\n"
            stream <<< "        return [\n"
            stream <<< "            (\"testExample\", testExample),\n"
            stream <<< "        ]\n"
            stream <<< "    }\n"
            stream <<< "}\n"
        }
    }
}

/// Represents a package type for the purposes of initialization.
enum InitMode: CustomStringConvertible {
    case library, executable, systemModule

    init(_ rawValue: String) throws {
        switch rawValue.lowercased() {
        case "library":
            self = .library
        case "executable":
            self = .executable
        case "system-module":
            self = .systemModule
        default:
            throw OptionParserError.invalidUsage("invalid initialization type: \(rawValue)")
        }
    }

    var description: String {
        switch self {
            case .library: return "library"
            case .executable: return "executable"
            case .systemModule: return "system-module"
        }
    }
}
