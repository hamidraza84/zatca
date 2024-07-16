require "net/http"
require "uri"
require "json"

class ZATCA::Client
  attr_accessor :before_submitting_request, :before_parsing_response

  PRODUCTION_BASE_URL = "https://gw-fatoora.zatca.gov.sa/e-invoicing/core".freeze
  SANDBOX_BASE_URL = "https://gw-apic-gov.gazt.gov.sa/e-invoicing/developer-portal".freeze
  SIMULATION_BASE_URL = "https://gw-fatoora.zatca.gov.sa/e-invoicing/simulation".freeze

  ENVIRONMENTS_TO_URLS_MAP = {
    production: PRODUCTION_BASE_URL,
    sandbox: SANDBOX_BASE_URL,
    simulation: SIMULATION_BASE_URL
  }.freeze

  DEFAULT_API_VERSION = "V2".freeze
  LANGUAGES = %w[ar en].freeze

  def initialize(
    username:,
    password:,
    language: "ar",
    version: DEFAULT_API_VERSION,
    environment: :production,
    verbose: false,
    before_submitting_request: nil,
    before_parsing_response: nil
  )
    raise "Invalid language: #{language}, Please use one of: #{LANGUAGES}" unless LANGUAGES.include?(language)

    @username = username
    @password = password
    @language = language
    @version = version
    @verbose = verbose

    @base_url = ENVIRONMENTS_TO_URLS_MAP[environment.to_sym] || PRODUCTION_BASE_URL

    @before_submitting_request = before_submitting_request
    @before_parsing_response = before_parsing_response
  end

  def report_invoice(uuid:, invoice_hash:, invoice:, cleared:)
    request(
      path: "invoices/reporting/single",
      method: :post,
      body: {
        uuid: uuid.force_encoding('UTF-8'),
        invoiceHash: invoice_hash.force_encoding('UTF-8'),
        invoice: invoice.force_encoding('UTF-8')
      },
      headers: {
        "Clearance-Status" => cleared ? "1" : "0"
      }
    )
  end

  def clear_invoice(uuid:, invoice_hash:, invoice:, cleared:)
    request(
      path: "invoices/clearance/single",
      method: :post,
      body: {
        uuid: uuid.force_encoding('UTF-8'),
        invoiceHash: invoice_hash.force_encoding('UTF-8'),
        invoice: invoice.force_encoding('UTF-8')
      },
      headers: {
        "Clearance-Status" => cleared ? "1" : "0"
      }
    )
  end

  def issue_csid(csr:, otp:)
    request(
      path: "compliance",
      method: :post,
      body: { csr: csr.force_encoding('UTF-8') },
      headers: { "OTP" => otp },
      authenticated: false
    )
  end

  def compliance_check(uuid:, invoice_hash:, invoice:)
    request(
      path: "compliance/invoices",
      method: :post,
      body: {
        uuid: uuid.force_encoding('UTF-8'),
        invoiceHash: invoice_hash.force_encoding('UTF-8'),
        invoice: invoice.force_encoding('UTF-8')
      }
    )
  end

  def issue_production_csid(compliance_request_id:)
    request(
      path: "production/csids",
      method: :post,
      body: { compliance_request_id: compliance_request_id.force_encoding('UTF-8') }
    )
  end

  def renew_production_csid(otp:, csr:)
    request(
      path: "production/csids",
      method: :patch,
      body: { csr: csr.force_encoding('UTF-8') },
      headers: { "OTP" => otp }
    )
  end

  private

  def request(method:, path:, body: {}, headers: {}, authenticated: true)
    url = "#{@base_url}/#{path}"
    headers = default_headers.merge(headers)

    before_submitting_request&.call(method, url, body, headers)
    log("Requesting #{method.upcase} #{url} with\n\nbody: #{body}\n\nheaders: #{headers}\n")

    uri = URI.parse(url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true

    request = case method
              when :post
                Net::HTTP::Post.new(uri.path, headers)
              when :patch
                Net::HTTP::Patch.new(uri.path, headers)
              else
                raise "Unsupported method: #{method}"
              end

    request.basic_auth(@username, @password) if authenticated
    request.body = body.to_json

    response = http.request(request)
    before_parsing_response&.call(response)
    log("Raw response: #{response}")

    if response.code.to_i >= 400
      return {
        message: response.message,
        details: response.body
      }
    end

    response_body = response.body

    parsed_body = if response.content_type == "application/json"
                    parse_json_or_return_string(response_body)
                  else
                    response_body
                  end

    log("Response body: #{parsed_body}")

    parsed_body
  end

  def default_headers
    {
      "Accept-Language" => @language,
      "Content-Type" => "application/json",
      "Accept-Version" => @version
    }
  end

  def parse_json_or_return_string(json)
    JSON.parse(json)
  rescue JSON::ParserError
    json
  end

  def log(message)
    return unless @verbose
    message = "\n\n---------------------\n\n#{message}\n\n"

    puts message
  end
end
