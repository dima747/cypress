SecretSauce = require "./util/secret_sauce_loader"

module.exports = (App, options) ->
  SecretSauce.Cli(App, options)
