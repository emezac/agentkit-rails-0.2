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

  # ─── Adaptive exploration operations and governed promotion ───────────────
  get "exploration", to: "exploration#index", as: :exploration
  post "exploration/reviews/:id/approve", to: "exploration#approve",
       as: :exploration_review_approve
  post "exploration/reviews/:id/reject", to: "exploration#reject",
       as: :exploration_review_reject
  post "exploration/reviews/:id/rollback", to: "exploration#rollback",
       as: :exploration_review_rollback

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
  post "a2a/message:send",   to: "a2a#send_message", as: :a2a_send_message
  get  "a2a/tasks/:id",      to: "a2a#get_task",     as: :a2a_get_task
  get  "a2a/tasks",          to: "a2a#list_tasks",   as: :a2a_list_tasks
  post "a2a/tasks/:id:cancel", to: "a2a#cancel_task", as: :a2a_cancel_task
  # Convenience REST alias over the same dispatcher.
  # ─── Team Memory Hub ───────────────────────────────────────────────────────
  get  "team_memory",              to: "team_memory#index",        as: :team_memory_index
  post "team_memory/create_asset", to: "team_memory#create_asset", as: :team_memory_create_asset
  get  "team_memory/activation/:id", to: "team_memory#activation", as: :team_memory_activation
end
