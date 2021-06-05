#!/usr/bin/env python

"""
The ultimate tool for generate linux tests.
"""

from __future__ import print_function

import argparse
import os
import re
import sys


def file_header(filename):
    return """import XCTest

///
/// NOTE: This file was generated by generate_linux_tests.py
///
/// Do NOT edit this file directly as it will be regenerated automatically when needed.
///
"""


def generate_test_extension_file(filename, classes, verbose):
    test_ext_file = re.sub(".swift", "+XCTest.swift", filename)
    if verbose:
        print("Creating file: {}".format(test_ext_file))

    with open(test_ext_file, "w") as file:
        file.write(file_header(test_ext_file))
        file.write("\n")

        for class_array in classes:
            file.write("extension " + class_array[0] + " {\n\n")
            file.write('    @available(*, deprecated, message: "not actually deprecated. Just deprecated to allow deprecated tests (which test deprecated functionality) without warnings")\n')
            file.write("    static var allTests: [(String, (" + class_array[0] + ") -> () throws -> Void)] {\n")
            file.write("        return [\n")

            for func in class_array[1]:
                file.write('            ("' + func + '", ' + func + "),\n")

            file.write("        ]\n")
            file.write("    }\n")
            file.write("}\n")


def generate_linux_main(tests_dir, all_test_sub_dir, files, verbose):
    filename = tests_dir + "/LinuxMain.swift"
    if verbose:
        print("Creating file: " + filename)

    with open(filename, "w") as file:
        file.write(file_header(filename))
        file.write("\n")

        file.write("#if os(Linux) || os(FreeBSD) || os(Android)\n")

        if all_test_sub_dir:
            all_test_sub_dir.sort()
        for test_sub_dir in all_test_sub_dir:
            file.write("    @testable import " + test_sub_dir + "\n")

        file.write("\n")
        file.write("// This protocol is necessary to we can call the 'run' method (on an existential of this protocol)\n")
        file.write("// without the compiler noticing that we're calling a deprecated function.\n")
        file.write("// This hack exists so we can deprecate individual tests which test deprecated functionality without\n")
        file.write("// getting a compiler warning...\n")
        file.write("protocol LinuxMainRunner { func run() }\n")
        file.write("\n")
        file.write("class LinuxMainRunnerImpl: LinuxMainRunner {\n")
        file.write('    @available(*, deprecated, message: "not actually deprecated. Just deprecated to allow deprecated tests (which test deprecated functionality) without warnings")\n')
        file.write("    func run() {\n")
        file.write("        XCTMain([\n")

        test_cases = []
        for classes in files:
            for class_array in classes:
                test_cases.append(class_array[0])

        if test_cases:
            test_cases.sort()
        for test_case in test_cases:
            file.write("            testCase(" + test_case + ".allTests),\n")

        file.write("        ])\n")
        file.write("    }\n")
        file.write("}\n\n")
        file.write("(LinuxMainRunnerImpl() as LinuxMainRunner).run()\n")
        file.write("#endif\n")


def parse_source_file(filename, verbose):
    if verbose:
        print("Parsing file:  " + filename)

    classes = []
    current_class = None
    in_if_linux = False
    in_else = False
    ignore = False

    #
    # Read the file line by line
    # and parse to find the class
    # names and func names
    #
    with open(filename) as file:
        for line in file.readlines():
            if in_if_linux:
                if re.match(r"#else", line):
                    in_else = True
                    ignore = True
                else:
                    if re.match(r"#end", line):
                        in_else = False
                        in_if_linux = False
                        ignore = False
            else:
                if re.match(r"#if[ \t]+os(Linux)", line):
                    in_if_linux = True
                    ignore = False

            if ignore:
                continue

            # Match class or func
            match = re.findall(r"class[ \t]+[a-zA-Z0-9_]*(?=[ \t]*:[ \t]*XCTestCase)|func[ \t]+test[a-zA-Z0-9_]*(?=[ \t]*\(\))", line)
            if not match:
                continue
            match = match[0]

            if (
                re.findall(r"class", match)
                and re.findall(r"class", match)[0] == "class"
            ):
                class_name = re.sub(r"^class[ \t]", "", match)
                #
                # Create a new class / func structure
                # and add it to the classes array.
                #
                current_class = [class_name, []]
                classes.append(current_class)
            else:
                func = re.sub(r"^func[ \t]", "", match)
                #
                # Add each func name the the class / func
                # structure created above.
                #
                current_class[1].append(func)

    return classes


def generate_linux_test_files(tests_dir, verbose):
    print("** Generating Linux Tests files **")
    
    all_test_sub_dir = []
    all_files = []

    for sub_dir_name in os.listdir(tests_dir):
        sub_dir = os.path.join(tests_dir, sub_dir_name)
        if not os.path.isdir(sub_dir):
            continue

        dir_has_classes = False
        for filename in os.listdir(sub_dir):
            filename = os.path.join(sub_dir, filename)
            if not os.path.isfile(filename):
                continue

            if re.search(r"Tests?.swift$", filename):
                file_classes = parse_source_file(filename, verbose)
                #
                # If there are classes in the
                # test source file, create an extension
                # file for it.
                #
                if len(file_classes) <= 0:
                    continue
                generate_test_extension_file(filename, file_classes, verbose)
                dir_has_classes = True
                all_files.append(file_classes)

        if dir_has_classes:
            all_test_sub_dir.append(sub_dir_name)

    #
    # Last step is the create a LinuxMain.swift file that
    # references all the classes and funcs in the source files.
    #
    if len(all_files) > 0:
        generate_linux_main(tests_dir, all_test_sub_dir, all_files, verbose)
    
    print("** All tests generated **")


def parse_args():
    parser = argparse.ArgumentParser(formatter_class=argparse.RawDescriptionHelpFormatter, description='Generate Linux Tests!')

    # -------------------------------------------------------------------------
    parser.add_argument(
        "-v", "--verbose", action="store_true", help="Enable verbose logging."
    )

    # -------------------------------------------------------------------------
    test_group = parser.add_argument_group("Test")

    test_group.add_argument("--tests-dir", default="Tests", help="The path for the tests directory (default: %(default)s).")

    return parser.parse_args()


def main():
    args = parse_args()
    generate_linux_test_files(args.tests_dir, args.verbose)
    

if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(1)