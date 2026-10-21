// Remuda's built-in Dark Horse provider for sandboxed pi.
//
// Registers `darkhorse` (ai.darkhorse.so, OpenAI-compatible) and fills its
// model list from GET /api/v1/models, so agents see whatever the catalog
// offers today. The key comes from the stored credential (Remuda stages
// auth.json from DARKHORSE_API_KEY in the agent's .env), falling back to the
// DARKHORSE_API_KEY environment variable.
//
// Without a key, or if the API cannot be reached, the provider lists no
// models and pi starts exactly as it would without this extension. It never
// throws at startup and never logs the key or response bodies.

const BASE_URL = "https://ai.darkhorse.so/api/v1";
const FETCH_TIMEOUT_MS = 10_000;
const DEFAULT_CONTEXT_WINDOW = 128_000;
const DEFAULT_MAX_TOKENS = 32_768;

type CatalogEntry = {
  id: string;
  display_name?: string;
  capabilities?: string[];
  context_window?: number;
};

// pi calls refreshModels several times per start; fetch once per process.
// Only a successful, non-empty catalog is cached, so a transient failure
// (or an aborted refresh) is retried on the next call.
let cached: unknown[] | undefined;

function toModel(entry: CatalogEntry) {
  const capabilities = entry.capabilities ?? [];
  return {
    id: entry.id,
    name: entry.display_name || entry.id,
    reasoning: capabilities.includes("reasoning"),
    input: capabilities.includes("vision") ? ["text", "image"] : ["text"],
    // The API bills; pi does not need prices.
    cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    contextWindow: entry.context_window || DEFAULT_CONTEXT_WINDOW,
    maxTokens: DEFAULT_MAX_TOKENS,
  };
}

async function fetchCatalog(key: string, signal?: AbortSignal): Promise<unknown[]> {
  const timeout = AbortSignal.timeout(FETCH_TIMEOUT_MS);
  try {
    const response = await fetch(`${BASE_URL}/models`, {
      headers: { Authorization: `Bearer ${key}`, Accept: "application/json" },
      signal: signal ? AbortSignal.any([signal, timeout]) : timeout,
    });
    if (!response.ok) return [];

    const body = (await response.json()) as { data?: CatalogEntry[] };
    if (!Array.isArray(body?.data)) return [];

    return body.data
      .filter((entry) => typeof entry?.id === "string" && (entry.capabilities ?? ["chat"]).includes("chat"))
      .map(toModel);
  } catch {
    return [];
  }
}

function resolveKey(credential: any): string | undefined {
  if (credential?.type === "api_key" && typeof credential.key === "string" && credential.key) {
    return credential.key;
  }
  return process.env.DARKHORSE_API_KEY || undefined;
}

export default function darkhorse(pi: any) {
  pi.registerProvider("darkhorse", {
    name: "Dark Horse",
    baseUrl: BASE_URL,
    api: "openai-completions",
    apiKey: "$DARKHORSE_API_KEY",
    async refreshModels(context: any) {
      if (cached) return cached;

      const key = resolveKey(context?.credential);
      if (!key) return [];

      const models = await fetchCatalog(key, context?.signal);
      if (models.length > 0) cached = models;
      return models;
    },
  });
}
