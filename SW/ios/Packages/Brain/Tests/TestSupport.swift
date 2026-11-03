import Foundation
import Brain

func toolJSON(device: String = "laptop", account: String = "a") -> Data {
    try! JSONSerialization.data(withJSONObject: ["kind": "select_target", "account_id": account, "device_id": device], options: [.sortedKeys])
}

func proposal(device: String = "laptop", account: String = "a") -> BrainProposal {
    let data = Data("[".utf8) + toolJSON(device: device, account: account) + Data("]".utf8)
    return ProposalDecoder.decode(data, accountID: account).proposals[0]
}

actor TestBrain: LlmBrain {
    private(set) var requests: [BrainRequest] = []
    let response: BrainResponse
    let failure: BrainError?
    init(_ response: BrainResponse = BrainResponse(proposals: [proposal()]), failure: BrainError? = nil) {
        self.response = response; self.failure = failure
    }
    func propose(_ request: BrainRequest) async throws -> BrainResponse {
        requests.append(request)
        if let failure { throw failure }
        return response
    }
    var count: Int { requests.count }
}

func request(_ text: String = "open dashboard", workload: BrainWorkload = .automatic) -> BrainRequest {
    BrainRequest(accountID: "a", transcript: text, context: "Fictional device laptop, project arm", workload: workload)
}
