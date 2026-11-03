// Future cloud STT/LLM work gets a separate authenticated Worker route/binding.
// Nothing here is wired into Room: providers never receive relay ciphertext,
// device credentials, Noise keys or policy/execution authority.
export interface FutureCloudService {
  fetch(request: Request): Promise<Response>;
}
