import Foundation
import IPAPatcherCore

enum PatchSessionState: Equatable {
    case idle
    case processing(
        fileName: String,
        fileSize: UInt64?,
        hostProfile: HostIPAProfile?,
        progress: PatchProgress
    )
    case incompatible(
        fileName: String,
        hostProfile: HostIPAProfile,
        report: IncompatibilityReport
    )
    case failed(
        fileName: String,
        hostProfile: HostIPAProfile?,
        title: String,
        message: String,
        technicalDetail: String
    )
    case cancelled(fileName: String)
    case readyToExport(
        result: PatchExecutionResult,
        exportNotice: String?
    )
    case exported(
        result: PatchExecutionResult,
        exportedFileName: String
    )

    var isProcessing: Bool {
        if case .processing = self { return true }
        return false
    }

    var exportableResult: PatchExecutionResult? {
        switch self {
        case .readyToExport(let result, _), .exported(let result, _):
            return result
        default:
            return nil
        }
    }
}
