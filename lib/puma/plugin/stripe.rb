# frozen_string_literal: true

require "puma"
require "puma/plugin"
require "stripe"

Puma::Plugin.create do
  def start(launcher)
    @launcher = launcher

    launcher.events.on_booted do
      if (url = forward_url)
        launcher.log_writer.log "Stripe: forwarding webhooks to #{url}"
        @pid = fork do
          exec StripeCLI.executable, "listen", "--forward-to", url.to_s, "--api-key", Stripe.api_key
        rescue Errno::ENOENT
          launcher.log_writer.log "[Stripe] Not found. See https://docs.stripe.com/stripe-cli#install"
        end
      else
        launcher.log_writer.log "[Stripe] No TCP bind to derive a forward host from (e.g. puma-dev's unix socket). " \
          'Set stripe_forward_host "myapp.test" in your puma config.'
      end
    end

    launcher.events.on_stopped { stop_stripe }
  end

  private
    def stop_stripe
      return unless @pid
      Process.waitpid(@pid, Process::WNOHANG)
      @launcher.log_writer.log "[Stripe] Stopping..."
      Process.kill(:INT, @pid)
      Process.wait(@pid)
    rescue Errno::ECHILD, Errno::ESRCH
    end

    def forward_url
      host, port = forward_host_and_port
      return unless host

      path = @launcher.options.fetch(:stripe_forward_to, "/stripe_events")
      URI::HTTP.build(host:, port:, path:)
    end

    def forward_host_and_port
      if (host = @launcher.options[:stripe_forward_host])
        host, port = host.split(":")
        [ host, port&.to_i ]
      elsif (tcp = @launcher.binder.ios.find { |io| io.respond_to?(:addr) && io.addr.first.start_with?("AF_INET") })
        _, port, host = tcp.addr
        host = "[#{host}]" if host.include?(":")
        [ host, port ]
      end
    end
end

module Puma
  class DSL
    def stripe_forward_to(path)
      @options[:stripe_forward_to] = path
    end

    def stripe_forward_host(host)
      @options[:stripe_forward_host] = host
    end
  end
end
