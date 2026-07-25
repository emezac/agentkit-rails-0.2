# frozen_string_literal: true

Agentkit::Engine.routes.draw do
  root to: "suggestions#index"

  # ─── HITL inbox ────────────────────────────────────────────────────────────
  resources :suggestions, only: %i[index show] do
    member do
      post :approve
      post :reject
      post :snooze
    end
  end

  # ─── Flow dashboard ────────────────────────────────────────────────────────
  resources :runs, only: %i[index show] do
    member { post :retry }
  end

  # ─── Factory ───────────────────────────────────────────────────────────────
  get  "factory",           to: "factory#index",    as: :factory
  post "factory/diagnose",  to: "factory#diagnose", as: :factory_diagnose
  get  "factory/report",    to: "factory#report",   as: :factory_report

  # ─── Cognition on demand ───────────────────────────────────────────────────
  post "cognition/:processor/run", to: "cognition#run", as: :cognition_run

  # ─── A2A ───────────────────────────────────────────────────────────────────
  post "a2a/rpc",      to: "a2a#rpc",      as: :a2a_rpc
  get  "a2a",          to: "a2a#card",     as: :a2a_card
  post "a2a/register", to: "a2a#register", as: :a2a_register
  # Convenience REST alias over the same dispatcher.
  post "a2a/:capability", to: "a2a#invoke", as: :a2a_invoke
end
