defmodule Bypass.Cert do
  @moduledoc """
  Generates a self-signed certificate for HTTPS testing.

  Creates a private key and a self-signed certificate in PEM format. These
  files can be referenced in the `certfile` and `keyfile` parameters of an
  HTTPS Endpoint.

  WARNING: only use the generated certificate for testing in a closed network
  environment, such as running a development server on `localhost`.
  For production, staging, or testing servers on the public internet, obtain a
  proper certificate, for example from [Let's Encrypt](https://letsencrypt.org).

  NOTE: when using Google Chrome, open chrome://flags/#allow-insecure-localhost
  to enable the use of self-signed certificates on `localhost`.

  This code was shamelessly copied from Phoenix mix.gen.cert mix task.
  """

  @doc false
  def generate do
    {certificate, private_key} =
      certificate_and_key(2048, "Self-signed test certificate", ["localhost"])

    {
      :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, private_key)])
      |> get_key_der(),
      :public_key.pem_encode([{:Certificate, certificate, :not_encrypted}])
      |> get_cert_der()
    }
  end

  @doc false
  def certificate_and_key(key_size, name, hostnames) do
    private_key =
      case generate_rsa_key(key_size, 65537) do
        {:ok, key} ->
          key

        {:error, :not_supported} ->
          raise("""
          Failed to generate an RSA key pair.

          Generating certificaesrequires Erlang/OTP 20 or later. Please upgrade to a
          newer version, or use another tool, such as OpenSSL, to generate a
          certificate.
          """)
      end

    public_key = extract_public_key(private_key)

    certificate =
      public_key
      |> new_cert(name, hostnames)
      |> :public_key.pkix_sign(private_key)

    {certificate, private_key}
  end

  def decode_pem_bin(pem_bin) do
    pem_bin |> :public_key.pem_decode() |> hd()
  end

  def decode_pem_entry(pem_entry) do
    :public_key.pem_entry_decode(pem_entry)
  end

  def decode_pem_entry(pem_entry, password) do
    password = String.to_charlist(password)
    :public_key.pem_entry_decode(pem_entry, password)
  end

  def encode_der(ans1_type, ans1_entity) do
    :public_key.der_encode(ans1_type, ans1_entity)
  end

  def split_type_and_entry(ans1_entry) do
    ans1_type = elem(ans1_entry, 0)
    {ans1_type, ans1_entry}
  end

  def get_cert_der(cert) do
    {cert_type, cert_entry} =
      cert
      |> decode_pem_bin()
      |> decode_pem_entry()
      |> split_type_and_entry()

    {cert_type, encode_der(cert_type, cert_entry)}
  end

  def get_key_der(key) do
    {key_type, key_entry} =
      key
      |> decode_pem_bin()
      |> decode_pem_entry("password")
      |> split_type_and_entry()

    {key_type, encode_der(key_type, key_entry)}
  end

  require Record

  # RSA key pairs

  Record.defrecordp(
    :rsa_private_key,
    :RSAPrivateKey,
    Record.extract(:RSAPrivateKey, from_lib: "public_key/include/OTP-PUB-KEY.hrl")
  )

  Record.defrecordp(
    :rsa_public_key,
    :RSAPublicKey,
    Record.extract(:RSAPublicKey, from_lib: "public_key/include/OTP-PUB-KEY.hrl")
  )

  defp generate_rsa_key(keysize, e) do
    private_key = :public_key.generate_key({:rsa, keysize, e})
    {:ok, private_key}
  rescue
    FunctionClauseError ->
      {:error, :not_supported}
  end

  defp extract_public_key(rsa_private_key(modulus: m, publicExponent: e)) do
    rsa_public_key(modulus: m, publicExponent: e)
  end

  # Certificates

  Record.defrecordp(
    :otp_tbs_certificate,
    :OTPTBSCertificate,
    Record.extract(:OTPTBSCertificate, from_lib: "public_key/include/OTP-PUB-KEY.hrl")
  )

  Record.defrecordp(
    :signature_algorithm,
    :SignatureAlgorithm,
    Record.extract(:SignatureAlgorithm, from_lib: "public_key/include/OTP-PUB-KEY.hrl")
  )

  Record.defrecordp(
    :validity,
    :Validity,
    Record.extract(:Validity, from_lib: "public_key/include/OTP-PUB-KEY.hrl")
  )

  Record.defrecordp(
    :otp_subject_public_key_info,
    :OTPSubjectPublicKeyInfo,
    Record.extract(:OTPSubjectPublicKeyInfo, from_lib: "public_key/include/OTP-PUB-KEY.hrl")
  )

  Record.defrecordp(
    :public_key_algorithm,
    :PublicKeyAlgorithm,
    Record.extract(:PublicKeyAlgorithm, from_lib: "public_key/include/OTP-PUB-KEY.hrl")
  )

  Record.defrecordp(
    :extension,
    :Extension,
    Record.extract(:Extension, from_lib: "public_key/include/OTP-PUB-KEY.hrl")
  )

  Record.defrecordp(
    :basic_constraints,
    :BasicConstraints,
    Record.extract(:BasicConstraints, from_lib: "public_key/include/OTP-PUB-KEY.hrl")
  )

  Record.defrecordp(
    :attr,
    :AttributeTypeAndValue,
    Record.extract(:AttributeTypeAndValue, from_lib: "public_key/include/OTP-PUB-KEY.hrl")
  )

  # OID values
  @rsaEncryption {1, 2, 840, 113_549, 1, 1, 1}
  @sha256WithRSAEncryption {1, 2, 840, 113_549, 1, 1, 11}

  @basicConstraints {2, 5, 29, 19}
  @keyUsage {2, 5, 29, 15}
  @extendedKeyUsage {2, 5, 29, 37}
  @subjectKeyIdentifier {2, 5, 29, 14}
  @subjectAlternativeName {2, 5, 29, 17}

  @organizationName {2, 5, 4, 10}
  @commonName {2, 5, 4, 3}

  @serverAuth {1, 3, 6, 1, 5, 5, 7, 3, 1}
  @clientAuth {1, 3, 6, 1, 5, 5, 7, 3, 2}

  defp new_cert(public_key, common_name, hostnames) do
    <<serial::unsigned-64>> = :crypto.strong_rand_bytes(8)

    # Dates must be in 'YYMMDD' format
    {{year, month, day}, _} =
      :erlang.timestamp()
      |> :calendar.now_to_datetime()

    yy = year |> Integer.to_string() |> String.slice(2, 2)
    mm = month |> Integer.to_string() |> String.pad_leading(2, "0")
    dd = day |> Integer.to_string() |> String.pad_leading(2, "0")

    not_before = yy <> mm <> dd

    yy2 = (year + 1) |> Integer.to_string() |> String.slice(2, 2)

    not_after = yy2 <> mm <> dd

    otp_tbs_certificate(
      version: :v3,
      serialNumber: serial,
      signature: signature_algorithm(algorithm: @sha256WithRSAEncryption, parameters: :NULL),
      issuer: rdn(common_name),
      validity:
        validity(
          notBefore: {:utcTime, '#{not_before}000000Z'},
          notAfter: {:utcTime, '#{not_after}000000Z'}
        ),
      subject: rdn(common_name),
      subjectPublicKeyInfo:
        otp_subject_public_key_info(
          algorithm: public_key_algorithm(algorithm: @rsaEncryption, parameters: :NULL),
          subjectPublicKey: public_key
        ),
      extensions: extensions(public_key, hostnames)
    )
  end

  defp rdn(common_name) do
    {:rdnSequence,
     [
       [attr(type: @organizationName, value: {:utf8String, "Phoenix Framework"})],
       [attr(type: @commonName, value: {:utf8String, common_name})]
     ]}
  end

  defp extensions(public_key, hostnames) do
    [
      extension(
        extnID: @basicConstraints,
        critical: true,
        extnValue: basic_constraints(cA: false)
      ),
      extension(
        extnID: @keyUsage,
        critical: true,
        extnValue: [:digitalSignature, :keyEncipherment]
      ),
      extension(
        extnID: @extendedKeyUsage,
        critical: false,
        extnValue: [@serverAuth, @clientAuth]
      ),
      extension(
        extnID: @subjectKeyIdentifier,
        critical: false,
        extnValue: key_identifier(public_key)
      ),
      extension(
        extnID: @subjectAlternativeName,
        critical: false,
        extnValue: Enum.map(hostnames, &{:dNSName, String.to_charlist(&1)})
      )
    ]
  end

  defp key_identifier(public_key) do
    :crypto.hash(:sha, :public_key.der_encode(:RSAPublicKey, public_key))
  end
end
