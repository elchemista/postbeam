defmodule Postbeam.SMTP.PropertiesTest do
  use ExUnit.Case, async: false
  @moduletag timeout: 120_000, capture_log: true

  for {module, properties} <- [
        postbeam_smtp_prop_rfc5322: [
          :prop_encode_no_crash,
          :prop_encode_scan_no_crash,
          :prop_encode_decode_match,
          :prop_encode_decode_group
        ],
        postbeam_smtp_prop_mimemail: [
          :prop_plaintext_encode_no_crash,
          :prop_multipart_encode_no_crash,
          :prop_plaintext_encode_decode_match,
          :prop_multipart_encode_decode_match,
          :prop_encode_decode_no_mime_version_match,
          :prop_quoted_printable,
          :prop_smtp_compatible
        ]
      ],
      property <- properties do
    test "#{module}.#{property}" do
      assert :proper.quickcheck(
               apply(unquote(module), unquote(property), []),
               [:quiet, numtests: 200, max_size: 30]
             )
    end
  end
end
