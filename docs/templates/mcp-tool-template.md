# MCP Tool Template

Use this design template when adding a planned Go Core MCP tool. Metadata does not enforce permissions: Core must enforce repository scope and approvals outside the model/client. MCP initialization and adapters are not yet implemented.

```json
{
  "name": "runnir_verb_noun",
  "status": "planned",
  "description": "One precise sentence describing the tool.",
  "readOnly": true,
  "requiresConfirmation": false,
  "dataAccess": ["selected-repository-only"],
  "privacy": {
    "returnsSecrets": false,
    "allowsArbitraryShell": false,
    "externalNetwork": "github-only"
  },
  "inputSchema": {
    "type": "object",
    "properties": {},
    "required": [],
    "additionalProperties": false
  },
  "outputSchema": {
    "type": "object",
    "properties": {},
    "required": [],
    "additionalProperties": false
  }
}
```

## Review Questions

- Does this tool need repository source, or only metadata?
- Can it be read-only?
- If it writes to GitHub, where is the confirmation screen?
- Could the output reveal a token, secret, private branch name, or personal data?
- Is the input schema strict enough for structured generation?
- Can the behavior be tested with fixtures?
