// CoreAIGraph.swift — run a stateless Core AI `.aimodel` graph with dictionary-in / dictionary-out
// tensors. Vendored from coreai-kit (`Sources/CoreAIKitVision/GraphModel.swift` + `TensorValue.swift`),
// which follows the public-API usage of apple/coreai-models (BSD-3-Clause).
//
// Vendored rather than depended on: the kit's package pulls a community fork of apple/coreai-models plus
// swift-transformers, while these two types link ONLY the system CoreAI framework — and they are all
// Kokoro needs. Changes from upstream: `VisionError` trimmed to the cases a stateless graph can raise and
// renamed `GraphError`; access made internal. Logic is unchanged.
//
// ---------------------------------------------------------------------------------------------------
// BSD 3-Clause License
//
// Copyright (c) 2026, Daisuke Majima
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
//
// 1. Redistributions of source code must retain the above copyright notice, this
//    list of conditions and the following disclaimer.
//
// 2. Redistributions in binary form must reproduce the above copyright notice,
//    this list of conditions and the following disclaimer in the documentation
//    and/or other materials provided with the distribution.
//
// 3. Neither the name of the copyright holder nor the names of its
//    contributors may be used to endorse or promote products derived from
//    this software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
// DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
// FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
// DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
// SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
// CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
// OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
// ---------------------------------------------------------------------------------------------------

import CoreAI
import Foundation

enum GraphError: Error, LocalizedError, Sendable {
    case functionNotFound(String)
    case statefulGraphUnsupported([String])
    case unknownInput(String)
    case shapeMismatch(input: String, expected: [Int], got: [Int])
    case dtypeMismatch(input: String, expected: String)
    case unsupportedScalarType(String)
    case missingOutput(String)

    var errorDescription: String? {
        switch self {
        case .functionNotFound(let name):
            return "Graph function '\(name)' not found in model"
        case .statefulGraphUnsupported(let states):
            return "GraphModel runs stateless graphs only; model declares states \(states)"
        case .unknownInput(let name):
            return "Model has no input named '\(name)'"
        case .shapeMismatch(let input, let expected, let got):
            return "Input '\(input)' expects shape \(expected), got \(got)"
        case .dtypeMismatch(let input, let expected):
            return "Input '\(input)' expects \(expected) scalars"
        case .unsupportedScalarType(let type):
            return "Unsupported scalar type \(type)"
        case .missingOutput(let name):
            return "Output '\(name)' missing after run"
        }
    }
}

/// A loaded, specialized graph function.
final class GraphModel: @unchecked Sendable {
    enum ComputeUnits: Sendable {
        /// `neuralEngine`/`gpu`/`cpu` express a *preference* over the full allowed set
        /// (`[cpu, gpu, neuralEngine]`); `cpuOnly` collapses the allowed set to the CPU alone.
        /// The distinction is load-bearing: a preference over a heterogeneous allowed set is the
        /// trigger for a Core AI placement defect that returns silently wrong numerics on some
        /// graphs (filed with Apple by the kit's author). Parity and gate runs should use `cpuOnly`,
        /// never `cpu`.
        case neuralEngine, gpu, cpu, cpuOnly

        var specializationOptions: SpecializationOptions {
            switch self {
            case .neuralEngine: return SpecializationOptions(preferredComputeUnitKind: .neuralEngine)
            case .gpu: return SpecializationOptions(preferredComputeUnitKind: .gpu)
            case .cpu: return SpecializationOptions(preferredComputeUnitKind: .cpu)
            case .cpuOnly: return SpecializationOptions.cpuOnly
            }
        }
    }

    private let function: InferenceFunction
    private let descriptor: InferenceFunctionDescriptor
    let inputNames: [String]
    let outputNames: [String]

    /// Loads and specializes a `.aimodel` (first load compiles on-device; cached afterwards).
    init(contentsOf url: URL, function name: String = "main", computeUnits: ComputeUnits = .gpu) async throws {
        let model = try await AIModel(contentsOf: url, options: computeUnits.specializationOptions)
        guard let descriptor = model.functionDescriptor(for: name) else {
            throw GraphError.functionNotFound(name)
        }
        guard descriptor.stateNames.isEmpty else {
            throw GraphError.statefulGraphUnsupported(descriptor.stateNames)
        }
        guard let function = try model.loadFunction(named: name) else {
            throw GraphError.functionNotFound(name)
        }
        self.descriptor = descriptor
        self.function = function
        self.inputNames = descriptor.inputNames
        self.outputNames = descriptor.outputNames
    }

    /// Runs one inference. Every declared input must be provided; scalar types convert
    /// automatically between float16/float32 where needed.
    func run(_ inputs: [String: TensorValue]) async throws -> [String: TensorValue] {
        var ndInputs: [String: NDArray] = [:]
        for (name, value) in inputs {
            guard case .ndArray(let d) = descriptor.inputDescriptor(of: name) else {
                throw GraphError.unknownInput(name)
            }
            guard d.shape.count == value.shape.count,
                  zip(d.shape, value.shape).allSatisfy({ $0 < 0 || $0 == $1 })
            else {
                throw GraphError.shapeMismatch(input: name, expected: d.shape, got: value.shape)
            }
            let resolved = d.resolvingDynamicDimensions(value.shape)
            ndInputs[name] = try value.makeNDArray(descriptor: resolved, inputName: name)
        }

        var rawOutputs = try await function.run(inputs: ndInputs)
        var outputs: [String: TensorValue] = [:]
        for name in outputNames {
            guard let array = rawOutputs.remove(name)?.ndArray else {
                throw GraphError.missingOutput(name)
            }
            outputs[name] = try TensorValue(reading: array)
        }
        return outputs
    }
}

/// A minimal host-side tensor for graph inputs/outputs. Copies in/out of the runtime's NDArray.
struct TensorValue: Sendable, Equatable {
    enum Storage: Equatable {
        case float16([Float16])
        case float32([Float])
        case int32([Int32])
    }

    let storage: Storage
    let shape: [Int]

    var count: Int { shape.reduce(1, *) }

    static func float16(_ scalars: [Float16], shape: [Int]) -> TensorValue {
        precondition(scalars.count == shape.reduce(1, *), "scalar count must match shape")
        return TensorValue(storage: .float16(scalars), shape: shape)
    }

    static func float32(_ scalars: [Float], shape: [Int]) -> TensorValue {
        precondition(scalars.count == shape.reduce(1, *), "scalar count must match shape")
        return TensorValue(storage: .float32(scalars), shape: shape)
    }

    static func int32(_ scalars: [Int32], shape: [Int]) -> TensorValue {
        precondition(scalars.count == shape.reduce(1, *), "scalar count must match shape")
        return TensorValue(storage: .int32(scalars), shape: shape)
    }

    /// Converting accessor: the scalars as Float, row-major.
    func floats() -> [Float] {
        switch storage {
        case .float16(let v): return v.map(Float.init)
        case .float32(let v): return v
        case .int32(let v): return v.map(Float.init)
        }
    }
}

// MARK: - NDArray bridge

extension TensorValue {
    /// Fills a fresh NDArray for the (resolved) descriptor, converting scalar type as needed.
    func makeNDArray(descriptor: NDArrayDescriptor, inputName: String) throws -> NDArray {
        var array = NDArray(descriptor: descriptor)
        switch (storage, descriptor.scalarType) {
        case (.float16(let v), .float16): fill(&array, with: v)
        case (.float32(let v), .float16): fill(&array, with: v.map(Float16.init))
        case (.float16(let v), .float32): fill(&array, with: v.map(Float.init))
        case (.float32(let v), .float32): fill(&array, with: v)
        case (.int32(let v), .int32): fill(&array, with: v)
        default:
            throw GraphError.dtypeMismatch(input: inputName, expected: "\(descriptor.scalarType)")
        }
        return array
    }

    /// Reads an output NDArray into host storage, branching on its own scalar type.
    init(reading array: NDArray) throws {
        let shape = array.shape
        let count = shape.reduce(1, *)
        switch array.scalarType {
        case .float16:
            self.init(storage: .float16(read(array, Float16.self, count)), shape: shape)
        case .float32:
            self.init(storage: .float32(read(array, Float.self, count)), shape: shape)
        case .int32:
            self.init(storage: .int32(read(array, Int32.self, count)), shape: shape)
        default:
            throw GraphError.unsupportedScalarType("\(array.scalarType)")
        }
    }
}

private func fill<T: BitwiseCopyable>(_ array: inout NDArray, with values: [T]) {
    var view = array.mutableView(as: T.self)
    view.copyElements(fromContentsOf: values)
}

private func read<T: BitwiseCopyable>(_ array: NDArray, _ type: T.Type, _ count: Int) -> [T] {
    array.view(as: T.self).withUnsafePointer { ptr, _, _ in
        Array(UnsafeBufferPointer(start: ptr, count: count))
    }
}
