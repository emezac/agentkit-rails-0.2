# Patrones de Host y Despliegue para `agentkit-rails`

`agentkit-rails` mantiene deliberadamente fuera del kernel la infraestructura de cómputo, los endpoints de webhooks y la distribución de artefactos. Esta guía reúne tres patrones probados para la aplicación **host Rails** en despliegues B2B y entornos regulados:

1. **Webhook Gate previo al agente** (evitar gasto de tokens y *prompt injection* desde eventos externos no autorizados).
2. **Inferencia privada con vLLM *self-hosted*** (*zero data leaving the VPC* vía `openai_compatible`).
3. **Distribución inmutable de Skills** mediante `Agentkit::SkillExport` + verificación de digest (compatible con registros OCI/`oras` o almacenamiento versionado).

Consulta también el ejemplo ejecutable [rails_webhook_vllm_host.rb](../examples/rails_webhook_vllm_host.rb).

---

## 1. Webhook Gate antes de despertar un agente

Nunca invoques `AgentLoop`, `Flow` ni `UnattendedRun` directamente desde un webhook externo. Filtra en el controlador o middleware del host Rails en cuatro pasos:

1. **Verificación de firma criptográfica en tiempo constante** (`OpenSSL::HMAC` + `Agentkit::Harness.secure_equal?`).
2. **Allowlist de identidad/asociación del remitente** (p. ej. `OWNER`/`MEMBER` en GitHub o cuentas verificadas en tu ERP/CRM).
3. **Deduplicación por delivery ID** (evitar re-ejecución de reintentos HTTP).
4. **Construcción explícita de `Agentkit::Context`** con `tenant_key`, `account` y `principal` resueltos del lado del servidor — jamás tomados del cuerpo del webhook.

Si el evento proviene de texto externo (issues, correos, comentarios de clientes), marca la herramienta de lectura con `metadata: { untrusted_output: true }` para activar el *taint tracking* de `AgentLoop` y restringir herramientas sensibles en `authorize:`.

---

## 2. Inferencia privada con vLLM *self-hosted* (VPC privada)

Para clientes financieros, legales o de salud que no pueden enviar contratos ni facturas a APIs externas, `agentkit-rails` soporta servidores OpenAI-compatible como **vLLM** sin cambios en el kernel:

```ruby
Agentkit.configure do |config|
  config.llm.adapter = :ruby_llm
  config.llm.api_base = ENV.fetch("VLLM_API_BASE") # ej. "http://vllm.internal.svc.cluster.local:8000/v1"
  config.llm.openai_api_key = ENV.fetch("VLLM_API_KEY", "vllm-internal")
  config.audit.redact = [/sk-[a-zA-Z0-9]+/, /Bearer\s+[A-Za-z0-9._-]+/]
end

Agentkit::ModelRouter.register(
  :private_vllm,
  model: "Qwen/Qwen2.5-72B-Instruct",
  provider: :openai_compatible,
  api_base: ENV.fetch("VLLM_API_BASE"),
  api_key: ENV.fetch("VLLM_API_KEY", "vllm-internal"),
  max_tokens: 4_096
)
```

> [!TIP]
> Si utilizas límites monetarios (`config.agent_loop.max_cost_usd`), registra una tarifa interna estimada en `Agentkit::LLM::Pricing` para tu modelo local o desactiva el límite en USD (`max_cost_usd: nil`) y acota por `max_tokens`, `max_turns` y `stall_limit`.

---

## 3. Distribución inmutable de Skills (`SkillExport` + Digest)

Cuando varias aplicaciones Rails comparten habilidades operativas (p. ej. empaquetadas como artefactos OCI con `oras` o en S3 versionado):

1. **Exporta** el bundle validado con `Agentkit::SkillExport.export(:mi_skill)` (genera `SKILL.md` + `tools.json` + `metadata`).
2. **Calcula y publica un digest inmutable** sobre `SKILL.md` y `tools.json` (`Agentkit::Harness.digest("SKILL.md" => ..., "tools.json" => ...)`).
3. **Al importar en otra app Rails**, verifica el digest antes de llamar a `Agentkit::SkillExport.import(bundle, origin: ..., author: ..., importer: ...)`.
4. **Mantén la cuarentena:** `SkillExport.import` nunca registra código ejecutable automáticamente; crea un asset en cuarentena que requiere aprobación humana (HITL) antes de activarse.
