// Copyright 2019-present the BinaryCodable authors. All Rights Reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import BinaryCodable
import Foundation
import XCTest

class ProtobufTests: XCTestCase {
  private let environment = TestConfig.environment

  func testProtoCompiler() throws {
    // Either set a PROTOC_PATH environment variable to the location of the protoc binary,
    // or place the protoc binary in <repo root>/bin/
    //
    // You can run the following from the <repo root>:
    //
    //     wget https://github.com/protocolbuffers/protobuf/releases/download/v3.6.1/protoc-3.6.1-osx-x86_64.zip
    //     unzip protoc-3.6.1-osx-x86_64.zip
    //
    XCTAssertTrue(FileManager.default.fileExists(atPath: environment.protocPath))
  }

  func testProtoCompilerPipeline() throws {
    // Given
    let data = try compileProto(definition: """
      message int_value {
        int32 int_value = 1;
      }
      """, message: "int_value", content: """
      int_value: 1
      """)

    // Then
    XCTAssertEqual([UInt8](data), [0x08, 0x01])
  }

  func testVarInt320Decoding() throws {
    // Given
    let data = try compileProto(definition: """
      message int_value {
        int32 int_value = 1;
      }
      """, message: "int_value", content: """
      int_value: 0
      """)
    let decoder = BinaryDataDecoder()

    // When
    do {
      let messages = try decoder.decode([ProtoMessage].self, from: data)

      // Then
      XCTAssertEqual(messages.count, 0)
    } catch let error {
      XCTFail(String(describing: error))
    }
  }

  func testVarInt32PositiveValueDecoding() throws {
    // Given
    let valuesToTest: [Int32] = [
      1, 127, // 1 byte range
      128, 16383, // 2 byte range
      16384, 2097151, // 3 byte range
      2097152, 268435455, // 4 byte range
      268435456, Int32.max, // 5 byte range
    ]

    for value in valuesToTest {
      let data = try compileProto(definition: """
        message int_value {
          int32 int_value = 1;
        }
        """, message: "int_value", content: """
        int_value: \(value)
        """)
      let decoder = BinaryDataDecoder()

      // When
      do {
        let messages = try decoder.decode([ProtoMessage].self, from: data)

        // Then
        XCTAssertEqual(messages.count, 1)
        guard let message = messages.first else {
          continue
        }
        XCTAssertEqual(message.fieldNumber, 1)
        XCTAssertEqual(message.value, .varint(rawValue: UInt64(value)))
      } catch let error {
        XCTFail("Value \(value): \(String(describing: error))")
      }
    }
  }

  func testVarInt32NegativeValueDecoding() throws {
    // Given
    let valuesToTest: [Int32] = [
      -1, -127,
      -128, -16383,
      -16384, -2097151,
      -2097152, -268435455,
      -268435456, Int32.min,
    ]

    for value in valuesToTest {
      let data = try compileProto(definition: """
        message int_value {
          int32 int_value = 1;
        }
        """, message: "int_value", content: """
        int_value: \(value)
        """)
      let decoder = BinaryDataDecoder()

      // When
      do {
        let messages = try decoder.decode([ProtoMessage].self, from: data)

        // Then
        XCTAssertEqual(messages.count, 1)
        guard let message = messages.first else {
          continue
        }
        XCTAssertEqual(message.fieldNumber, 1)
        XCTAssertEqual(message.value, .varint(rawValue: UInt64(bitPattern: Int64(value))))
      } catch let error {
        XCTFail("Value \(value): \(String(describing: error))")
      }
    }
  }

  func testMultipleInt32Decoding() throws {
    // Given
    let data = try compileProto(definition: """
      message int_value {
        int32 first_value = 1;
        int32 second_value = 2;
        int32 third_value = 3;
      }
      """, message: "int_value", content: """
      first_value: 1
      second_value: 128
      third_value: 268435456
      """)
    let decoder = BinaryDataDecoder()

    // When
    do {
      let messages = try decoder.decode([ProtoMessage].self, from: data)

      // Then
      XCTAssertEqual(messages, [
        ProtoMessage(fieldNumber: 1, value: .varint(rawValue: 1)),
        ProtoMessage(fieldNumber: 2, value: .varint(rawValue: 128)),
        ProtoMessage(fieldNumber: 3, value: .varint(rawValue: 268435456)),
        ])
      XCTAssertEqual(messages.count, 3)
    } catch let error {
      XCTFail(String(describing: error))
    }
  }

  func testGeneratedMessageDecoding() throws {
    // Given
    let data = try compileProto(definition: """
      message int_value {
        int32 first_value = 1;
        int32 second_value = 2;
        int32 third_value = 3;
      }
      """, message: "int_value", content: """
      first_value: 1
      second_value: 128
      third_value: 268435456
      """)
    let decoder = BinaryDataDecoder()

    // When
    do {
      let message = try decoder.decode(Message.self, from: data)

      // Then
      XCTAssertEqual(message.value1, 1)
      XCTAssertEqual(message.value2, 128)
      XCTAssertEqual(message.value3, 268435456)
    } catch let error {
      XCTFail(String(describing: error))
    }
  }

  private func compileProto(definition: String, message: String, content: String) throws -> Data {
    let input = temporaryFile()
    let proto = temporaryFile()
    let output = temporaryFile()

    let package = "\(type(of: self))"
    let header = """
    syntax = "proto3";

    package \(package);

    """
    try (header + definition).write(to: proto, atomically: true, encoding: .utf8)
    try content.write(to: input, atomically: true, encoding: .utf8)

    let task = Process()
    task.launchPath = environment.protocPath
    task.standardInput = try FileHandle(forReadingFrom: input)
    task.standardOutput = try FileHandle(forWritingTo: output)
    task.arguments = [
      "--encode",
      "\(package).\(message)",
      "-I",
      proto.deletingLastPathComponent().absoluteString.replacingOccurrences(of: "file://", with: ""),
      proto.absoluteString.replacingOccurrences(of: "file://", with: "")
    ]
    task.launch()
    task.waitUntilExit()

    return try Data(contentsOf: output)
  }
}

private func temporaryFile() -> URL {
  let template = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("file.XXXXXX") as NSURL
  var buffer = [Int8](repeating: 0, count: Int(PATH_MAX))
  template.getFileSystemRepresentation(&buffer, maxLength: buffer.count)
  let fd = mkstemp(&buffer)
  guard fd != -1 else {
    preconditionFailure("Unable to create temporary file.")
  }
  return URL(fileURLWithFileSystemRepresentation: buffer, isDirectory: false, relativeTo: nil)
}

private struct TestConfig {
  var testAgainstProtoc = true
  var protocPath: String = {

    return URL(fileURLWithPath: #file)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("bin")
      .appendingPathComponent("protoc")
      .absoluteString
      .replacingOccurrences(of: "file://", with: "")
  }()

  static var environment: TestConfig {
    var config = TestConfig()
    if let protocPath = getEnvironmentVariable(named: "PROTOC_PATH") {
      config.protocPath = protocPath
    }
    return config
  }
}

private func getEnvironmentVariable(named name: String) -> String? {
  if let environmentValue = getenv(name) {
    return String(cString: environmentValue)
  } else {
    return nil
  }
}