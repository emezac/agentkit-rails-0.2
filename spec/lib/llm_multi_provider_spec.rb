# frozen_string_literal: true

require "spec_helper"

# Dos gateways compatibles conviviendo, que es lo que hace falta para sobrevivir
# a una cuota agotada.
#
# El adaptador llamaba a `RubyLLM.configure` una vez, globalmente, y lo
# memoizaba: configurar un segundo gateway pisaba al primero. Una cadena de
# fallback que cruzara proveedores era imposible — justo lo que se necesita
# cuando el proveedor de siempre se queda sin cuota.
#
# Ahora las credenciales viajan en el perfil y el adaptador arma un contexto de
# ruby_llm por credencial, sin tocar la configuración global.
RSpec.describe "Perfiles con proveedor propio" do
  before do
    Agentkit::LLM::Adapters::Fake.reset!
    Agentkit.configure do |c|
      c.llm.adapter = :fake
      c.llm.profiles[:principal] = Agentkit::ModelProfile.new(
        model: "modelo-a", provider: :openrouter,
        api_base: "https://openrouter.ai/api/v1", api_key: "clave-a",
        fallback: :respaldo
      )
      c.llm.profiles[:respaldo] = Agentkit::ModelProfile.new(
        model: "modelo-b", provider: :mindshub,
        api_base: "https://api.mindshub.ai/v1", api_key: "clave-b"
      )
    end
  end

  after { Agentkit.reset! if Agentkit.respond_to?(:reset!) }

  it "cada perfil llega al adaptador con sus propias credenciales" do
    Agentkit::LLM::Adapters::Fake.respond_with("desde a")
    Agentkit::LLM.complete("hola", model: :principal)

    llamada = Agentkit::LLM::Adapters::Fake.calls.last
    expect(llamada.api_base).to eq("https://openrouter.ai/api/v1")
    expect(llamada.api_key).to eq("clave-a")
  end

  it "el respaldo usa las suyas, no las del principal" do
    Agentkit::LLM::Adapters::Fake.respond_with("desde b")
    Agentkit::LLM.complete("hola", model: :respaldo)

    llamada = Agentkit::LLM::Adapters::Fake.calls.last
    expect(llamada.api_base).to eq("https://api.mindshub.ai/v1")
    expect(llamada.api_key).to eq("clave-b")
  end

  # El caso que motiva todo: el primero se queda sin cuota y el segundo contesta.
  #
  # Antes esto no podía funcionar por dos motivos independientes: la cuota
  # agotada se clasificaba como transitoria, así que se reintentaba contra el
  # mismo proveedor y la cadena nunca avanzaba; y aunque hubiera avanzado, el
  # segundo perfil habría usado la configuración global del primero.
  it "cuando al principal se le agota la cuota, contesta el respaldo" do
    Agentkit::LLM::Adapters::Fake.fail_on(
      model: "modelo-a", error: Agentkit::PermanentError,
      message: "Rate limit exceeded: free-models-per-day. " \
               "Add 10 credits to unlock 1000 free model requests per day"
    )
    Agentkit::LLM::Adapters::Fake.respond_with("contestó el respaldo")

    respuesta = Agentkit::LLM.complete("hola", model: :principal)

    expect(respuesta.content).to eq("contestó el respaldo")
    expect(Agentkit::LLM::Adapters::Fake.calls.map(&:model)).to eq(%w[modelo-a modelo-b])
    expect(Agentkit::LLM::Adapters::Fake.calls.last.api_base).to eq("https://api.mindshub.ai/v1")
  end

  # Un perfil sin credenciales propias sigue usando la configuración global, que
  # es como estaba configurado todo antes de esto.
  it "un perfil sin credenciales no exige ninguna" do
    Agentkit.config.llm.profiles[:simple] = Agentkit::ModelProfile.new(model: "modelo-c")
    Agentkit::LLM::Adapters::Fake.respond_with("ok")

    Agentkit::LLM.complete("hola", model: :simple)

    llamada = Agentkit::LLM::Adapters::Fake.calls.last
    expect(llamada.api_base).to be_nil
    expect(llamada.api_key).to be_nil
  end
end
