import Config

information =
  Keyword.filter(
    [
      name: System.get_env("RELAY_NAME"),
      description: System.get_env("RELAY_DESC"),
      pubkey: System.get_env("OWNER_PUBKEY"),
      contact: System.get_env("OWNER_CONTACT")
    ],
    fn {_, v} -> !is_nil(v) end
  )

config :noxir, :information, information

auth_required = System.get_env("AUTH_REQUIRED", "false") |> String.downcase() == "true"
allowed_pubkeys = 
  case System.get_env("ALLOWED_PUBKEYS") do
    nil -> []
    pubkeys -> String.split(pubkeys, ",") |> Enum.map(&String.trim/1)
  end

config :noxir, :auth,
  required: auth_required,
  allowed_pubkeys: allowed_pubkeys
