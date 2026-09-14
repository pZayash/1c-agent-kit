# QMD query syntax

Companion to [`qmd-search.md`](qmd-search.md). Typed lines per sub-query.

Cross-doc neighbors — [`qmd links`](qmd-search.md#retrieval--links), not `query`.

## Grammar

```ebnf
query          = expand_query | query_document ;
expand_query   = text | explicit_expand ;
explicit_expand= "expand:" text ;
query_document = [ intent_line ] { typed_line } ;
intent_line    = "intent:" text newline ;
typed_line     = type ":" text newline ;
type           = "lex" | "vec" | "hyde" ;
text           = quoted_phrase | plain_text ;
quoted_phrase  = '"' { character } '"' ;
plain_text     = { character } ;
newline        = "\n" ;
```

## Types

| Type | Backend | Role |
| --- | --- | --- |
| `lex` | BM25 | Keywords, precision |
| `vec` | Vector | Natural language, recall |
| `hyde` | Vector | Hypothetical answer passage (~50–100 words) |

## Default (no prefixes)

Single line, no `lex:`/`vec:`/`hyde:` → **expand query**. Expansion model emits lex/vec/hyde automatically.

```text
how does authentication work
expand: how does authentication work
```

Equivalent. Cannot mix with typed lines in one document.

## Lex

```ebnf
lex_query   = { lex_term } ;
lex_term    = negation | phrase | word ;
negation    = "-" ( phrase | word ) ;
phrase      = '"' { character } '"' ;
word        = { letter | digit | "'" } ;
```

| Token | Meaning | Example |
| --- | --- | --- |
| word | Prefix match | `perf` → performance |
| `"phrase"` | Exact phrase | `"rate limiter"` |
| `-word` | Exclude | `-sports` |
| `-"phrase"` | Exclude phrase | `-"test data"` |

```text
lex: CAP theorem consistency
lex: "machine learning" -"deep learning"
lex: auth -oauth -saml
```

## Vec

Natural language only. No lex operators.

```text
vec: how does the rate limiter handle burst traffic
vec: what is the tradeoff between consistency and availability
```

## Hyde

Hypothetical answer you expect from a doc (50–100 words).

```text
hyde: The rate limiter uses a sliding window with a 60-second window.
When a client exceeds 100 requests per minute, subsequent requests return 429.
```

## Multi-line

Combine types. **First typed line = 2× fusion weight.**

```text
lex: rate limiter algorithm
vec: how does rate limiting work in the API
hyde: The API implements rate limiting using a token bucket...
```

## Expand

Standalone. Not mixed with `lex`/`vec`/`hyde` lines.

```text
expand: error handling best practices
```

Same as plain one-liner without `expand:`.

## Intent

Background. Disambiguates expansion, reranking, snippets. **Does not search alone.**

- Max one `intent:` per document
- Cannot be only line — need ≥1 of `lex`/`vec`/`hyde`
- Also: CLI `--intent` or MCP `intent`

```text
intent: web page load times and Core Web Vitals
lex: performance
vec: how to improve performance
```

## Constraints

- Top level: either one expand query **or** multi-line query document
- Inside document: only `lex`, `vec`, `hyde`, `intent` — no `expand:`
- Lex operators only on `lex:` lines
- One `intent:` max
- Empty lines ignored; trim whitespace

## API shapes (MCP/HTTP)

```json
{
  "q": "lex: CAP theorem\nvec: consistency vs availability",
  "collections": ["docs"],
  "limit": 10
}
```

```json
{
  "searches": [
    { "type": "lex", "query": "CAP theorem" },
    { "type": "vec", "query": "consistency vs availability" }
  ]
}
```

```json
{
  "searches": [{ "type": "lex", "query": "performance" }],
  "intent": "web page load times and Core Web Vitals"
}
```

## CLI examples

```bash
qmd query "how does auth work"

qmd query $'lex: auth token\nvec: how does authentication work'

qmd query $'lex: keywords\nvec: question\nhyde: hypothetical answer...'

qmd query $'intent: web performance and latency\nlex: performance\nvec: how to improve performance'

qmd query --intent "web performance and latency" "performance"
```
