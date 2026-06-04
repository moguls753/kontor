Rails.application.routes.draw do
  resource :session, only: %i[ new create destroy ]
  resource :user, only: %i[ create ]
  resources :passwords, param: :token
  get "me", to: "users#me"

  namespace :api do
    namespace :v1 do
      resource :credentials, only: %i[ show create update ] do
        post :test, on: :collection
      end
      resources :institutions, only: %i[ index ]
      resources :bank_connections, only: %i[ index show create destroy ] do
        collection do
          # Stable Open Banking callback (no per-connection id): the connection is
          # resolved from the `state` param the provider echoes back. Lets a single
          # redirect URL be registered with the provider (e.g. Enable Banking).
          get :callback
        end
        member do
          get :callback
          post :sync
          post :reconnect
          post :confirm_2fa
        end
      end
      resources :categories, only: %i[ index create update destroy ] do
        collection do
          post :create_defaults
          post :suggest
        end
      end
      resources :accounts, only: %i[ index show update ]
      resources :transactions, only: %i[ index ] do
        post :categorize, on: :collection
      end
      resource :dashboard, only: %i[ show ]
    end
  end

  root "home#index"

  get "up" => "rails/health#show", as: :rails_health_check
end
