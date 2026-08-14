# frozen_string_literal: true

# ==============================================================================
# AgentKit v0.3 — Ejemplo Completo de Demostración y Verificación
# ==============================================================================
# Este script demuestra todas las capacidades introducidas en AgentKit v0.3:
#   1. Épica 1: RAG Nativo y Orquestación Distribuida (CoordinatorFlow)
#   2. Épica 2: Team Memory Hub (ACL, Wiki Engine, CodeGraph, SkillExtractor, LayeredPipeline)
#   3. Épica 3: Memoria Avanzada (Layers L0-L3, ColdStart, CustomPrompts, Time-Recall, mem: commands, SkillExport)
#   4. Llamada real/simulada al LLM usando la API KEY de Gemini desde el archivo .env
# ==============================================================================

require "bundler/setup"
require "agentkit"
require "json"
require "time"
require "tmpdir"
require "net/http"
require "uri"

# Cargar variables de entorno desde .env si existe
env_file = File.expand_path("../.env", __dir__)
if File.exist?(env_file)
  File.readlines(env_file).each do |line|
    line = line.strip
    next if line.empty? || line.start_with?("#")

    k, v = line.split("=", 2)
    ENV[k.strip] = v.strip if k && v
  end
end

gemini_key = ENV["GEMINI_API_KEY"]
puts "=================================================================="
puts "🚀 Ejecutando AgentKit v0.3.0 Demo"
puts "🔑 GEMINI_API_KEY detectada: #{gemini_key ? "#{gemini_key[0..7]}..." : 'No configurada (usando modo mock)'}"
puts "==================================================================\n\n"

# Configurar AgentKit en modo de prueba / memoria
Agentkit::Flow.test_mode!
Agentkit.reset!
Agentkit.config.memory.store = :memory
Agentkit.config.rag.store = :memory
Agentkit.config.flow.store = :memory

# ------------------------------------------------------------------------------
# SECTION 1: ÉPICA 1 — RAG NATIVO Y AGENTE CON USE_KNOWLEDGE
# ------------------------------------------------------------------------------
puts "--- 📚 1. Demostración RAG Nativo & AgentConcern ---"

# 1.1 Ingestar documentos en un corpus de conocimiento
corpus_docs = [
  {
    "id" => "sec_standard_1",
    "text" => "Estándar de Seguridad API: Todas las peticiones deben usar HTTPS y tokens JWT con expiración de 15 minutos.",
    "department" => "security",
    "chapter_index" => 1
  },
  {
    "id" => "sec_standard_2",
    "text" => "Política de Contraseñas: Las contraseñas deben rotarse cada 90 días y requerir mínimo 14 caracteres con 2FA habilitado.",
    "department" => "security",
    "chapter_index" => 2
  },
  {
    "id" => "hr_policy_1",
    "text" => "Política de RH: Los empleados cuentan con 20 días de vacaciones pagadas y horario flexible.",
    "department" => "hr",
    "chapter_index" => 1
  }
]

indexed_res = Agentkit::RAG.index(
  corpus_name: "enterprise_rules",
  source: corpus_docs,
  chunk_documents: false
)
puts "✅ Indexados #{indexed_res[:chunks]} documentos en el corpus 'enterprise_rules'."

# 1.2 Definir un agente que usa el DSL use_knowledge
class SecurityComplianceAgent < Agentkit::Agent
  use_knowledge :enterprise_rules, filter: { department: "security" }

  def call(input)
    query = input[:query]
    retrieved_chunks = rag_retrieve(query)
    context_text     = rag_context(query)

    Agentkit::Result.ok({
      chunks_found: retrieved_chunks.size,
      top_chunk: retrieved_chunks.first&.dig("text"),
      formatted_context: context_text
    })
  end
end

compliance_agent = SecurityComplianceAgent.new
res_rag = compliance_agent.call(query: "tokens JWT")
puts "🔍 Búsqueda RAG realizada por SecurityComplianceAgent:"
puts "   - Chunks encontrados: #{res_rag.value[:chunks_found]}"
puts "   - Contenido relevante: #{res_rag.value[:top_chunk]}\n\n"


# ------------------------------------------------------------------------------
# SECTION 2: ÉPICA 1.5 — ORQUESTACIÓN RAG DISTRIBUIDA (COORDINATOR FLOW)
# ------------------------------------------------------------------------------
puts "--- ⚡ 2. Demostración de RAG Distribuido (CoordinatorFlow) ---"

document_text = <<~TEXT
  Capítulo 1: Introducción a la Arquitectura de Agentes
  Los agentes autónomos combinan planificación, memoria a largo plazo y herramientas ejecutables para resolver tareas complejas de forma independiente.

  Capítulo 2: Patrones de Orquestación Paralela
  Para procesar documentos masivos, se utiliza una estrategia de chunking por capítulos y sub-agentes que ejecutan la ingesta y análisis en paralelo antes de realizar la reducción.
TEXT

# Ejecutar el flujo coordinador map/reduce distribuido
flow_input = {
  pdf_text: document_text,
  corpus_name: "distributed_book",
  strategy: :heading_regex,
  max_slice_mb: 5,
  max_concurrency: 4
}

flow_res = Agentkit::RAG::CoordinatorFlow.call(**flow_input)
puts "✅ Flujo CoordinatorFlow completado:"
puts "   - Exitoso?: #{flow_res.ok?}"
puts "   - Referencias sintetizadas: #{flow_res.value[:global_index].inspect}\n\n"


# ------------------------------------------------------------------------------
# SECTION 3: ÉPICA 2 — TEAM MEMORY HUB (TENCENTDB AGENT MEMORY)
# ------------------------------------------------------------------------------
puts "--- 🏛️ 3. Demostración de Team Memory Hub ---"

# 3.1 Crear un equipo y evaluar ACL
team = Agentkit::TeamMemory.create_team(name: "CyberSecurityTeam", description: "Equipo de respuesta a incidentes")
puts "✅ Equipo creado: #{team.name} (ID: #{team.id})"

# Crear asset privado y comprobar permisos ACL
private_asset = Agentkit::TeamMemory.create_asset(
  asset_type: "chat_memory",
  name: "incident_vault_keys",
  team_id: team.id,
  visibility: "private",
  owner_id: 101
)

is_accessible_owner = Agentkit::TeamMemory::ACL.accessible?(private_asset, owner_id: 101)
is_accessible_other = Agentkit::TeamMemory::ACL.accessible?(private_asset, owner_id: 999)
puts "🔒 Evaluación ACL de Asset Privado:"
puts "   - Acceso para dueño (ID 101): #{is_accessible_owner}"
puts "   - Acceso para tercero (ID 999): #{is_accessible_other}"

# 3.2 Wiki Engine
wiki = Agentkit::TeamMemory::Wiki.create_wiki(name: "SecOpsWiki", team_id: team.id)
page = Agentkit::TeamMemory::Wiki.add_page(
  wiki,
  title: "Protocolo DDoS",
  content: "En caso de ataque DDoS, activar Cloudflare y consultar [[Playbook Mitigación]] y [[Firewall Rules]]."
)
puts "📖 Wiki Page agregada: '#{page.title}' con enlaces detectados: #{page.links.inspect}"

# 3.3 CodeGraph Static Analysis
sample_ruby_code = File.join(Dir.tmpdir, "auth_service_demo.rb")
File.write(sample_ruby_code, <<~RUBY)
  module Security
    class Authenticator
      def verify_token
        puts "Token verificado"
      end
    end
  end
RUBY

code_graph = Agentkit::TeamMemory::CodeGraph.create_graph(name: "AuthRepo", team_id: team.id)
Agentkit::TeamMemory::CodeGraph.index_files(code_graph, [sample_ruby_code])
symbols = Agentkit::TeamMemory::CodeGraph.all_symbols(code_graph)
puts "💻 CodeGraph símbolos indexados: #{symbols.map(&:name).join(', ')}"

# 3.4 SkillExtractor
transcript = [
  "User: ¿Cómo realizo el deploy seguro?",
  "Agent: Step 1: Correr escaneo SAST. Step 2: Validar firmas container. Step 3: Aplicar migración en staging."
]
extracted_skill = Agentkit::TeamMemory::SkillExtractor.extract(conversation: transcript, name: "DeploySeguroSkill", team_id: team.id)
puts "🛠️ Skill extraído automáticamente: '#{extracted_skill.name}' con #{extracted_skill.content['steps'].size} pasos."

# 3.5 LayeredPipeline (L0 -> L1 -> L2 -> L3)
raw_messages = [
  "User prefiere notificaciones por Slack en incidentes graves.",
  "Decisión de equipo: El tiempo de rotación de credenciales es 30 días."
]
l1_atoms = Agentkit::TeamMemory::LayeredPipeline.process_l0_to_l1(raw_messages, source_agent: "IncidentAgent")
l2_scene = Agentkit::TeamMemory::LayeredPipeline.process_l1_to_l2(l1_atoms, scene_name: "IncidentResponseScene", team_id: team.id)
l3_persona = Agentkit::TeamMemory::LayeredPipeline.process_l2_to_l3([l2_scene], persona_name: "SecOpsExpertPersona", team_id: team.id)

puts "🧬 Layered Pipeline Ejecutado:"
puts "   - L1 Átomos creados: #{l1_atoms.size}"
puts "   - L2 Escena consolidada: #{l2_scene.name}"
puts "   - L3 Persona/Skill final: #{l3_persona.name}\n\n"


# ------------------------------------------------------------------------------
# SECTION 4: ÉPICA 3 — MEJORAS DE MEMORIA AVANZADA
# ------------------------------------------------------------------------------
puts "--- 🌟 4. Demostración de Memoria Avanzada ---"

# 4.1 CustomPrompts
Agentkit::Memory::CustomPrompts.register(
  "cyber_sec",
  prompt_type: "extraction",
  template: "Extraer vulnerabilidades para el tenant {tenant}: {input}",
  version: "1.2.0"
)
rendered_prompt, version = Agentkit::Memory::CustomPrompts.render(
  "cyber_sec",
  prompt_type: "extraction",
  default_template: "Default",
  context: { tenant: "AcmeBank", input: "Puerto 8080 abierto sin TLS." }
)
puts "✏️ Custom Prompt Renderizado (v#{version}): '#{rendered_prompt}'"

# 4.2 Time-window Recall
t1 = Time.now - 3600
mem_past = Agentkit::Memory.store("Observación de red pasada", tags: ["net_audit"])
mem_past.created_at = t1

mem_recent = Agentkit::Memory.store("Observación de red reciente", tags: ["net_audit"])

recalled_time = Agentkit::Memory.recall("Observación", since: Time.now - 1800)
puts "⏱️ Time-filtered Recall (últimos 30 mins): #{recalled_time.map(&:content).inspect}"

# 4.3 Comandos interactivos mem: en Chat
chat_status = Agentkit::Chat.say("mem:status")
puts "💬 Chat Command 'mem:status': #{chat_status.message}"

# 4.4 SkillExport & Import
export_bundle = Agentkit::SkillExport.export(:DeploySeguroSkill)
puts "📦 Skill Export Bundle generado:"
puts "   - SKILL.md preview: #{export_bundle['SKILL.md'].lines.first.strip}"

imported_skill = Agentkit::SkillExport.import(export_bundle)
puts "📥 Skill Import re-registrado: #{imported_skill.name}\n\n"


# ------------------------------------------------------------------------------
# SECTION 5: INTEG CON GEMINI LLM API REAL / SIMULADA
# ------------------------------------------------------------------------------
puts "--- 🤖 5. Integración y llamada al Modelo LLM (Gemini) ---"

if gemini_key && !gemini_key.empty?
  puts "📡 Realizando llamada HTTP directa a la API de Gemini (model: gemini-2.5-flash)..."

  uri = URI.parse("https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=#{gemini_key}")
  header = { "Content-Type" => "application/json" }

  prompt_text = "Genera un breve resumen de 2 oraciones sobre las ventajas de usar un RAG nativo con memoria de equipo en agentes AI."
  body = {
    contents: [
      {
        parts: [
          { text: prompt_text }
        ]
      }
    ]
  }

  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true
  request = Net::HTTP::Post.new(uri.request_uri, header)
  request.body = body.to_json

  response = http.request(request)

  if response.code == "200"
    data = JSON.parse(response.body)
    answer = data.dig("candidates", 0, "content", "parts", 0, "text")
    puts "✨ Respuesta recibida de Gemini API:"
    puts "   \"#{answer.to_s.strip}\""
  else
    puts "⚠️ Respuesta de Gemini API (Status #{response.code}): #{response.body[0..200]}"
  end
else
  puts "⚠️ GEMINI_API_KEY no encontrada. Ejecutando respuesta simulada con AgentKit Fake Adapter."
  response = Agentkit::LLM.complete("Resumen RAG", model: :fake)
  puts "✨ Respuesta Fake Adapter: \"#{response.content}\""
end

puts "\n=================================================================="
puts "🎉 DEMO VERIFICACIÓN AGENTKIT V0.3.0 FINALIZADA CON ÉXITO"
puts "=================================================================="
