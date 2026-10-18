//// The examples from AWS's documentation of Signature Version 4 for S3,
//// which publish the signature each request must get.

import gleam/http
import gleam/http/request
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam/time/timestamp
import howdy/storage/internal/sigv4

fn credentials() {
  sigv4.Credentials(
    access_key_id: "AKIAIOSFODNN7EXAMPLE",
    secret_access_key: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
    session_token: None,
    region: "us-east-1",
  )
}

fn may_24_2013() {
  let assert Ok(time) = timestamp.parse_rfc3339("2013-05-24T00:00:00Z")
  time
}

fn base(method, path) {
  request.new()
  |> request.set_method(method)
  |> request.set_host("examplebucket.s3.amazonaws.com")
  |> request.set_path(path)
  |> request.set_body(<<>>)
}

fn signature_of(signed: request.Request(BitArray)) -> String {
  let assert Ok(authorization) = request.get_header(signed, "authorization")
  let assert Ok(#(_, signature)) =
    string.split_once(authorization, "Signature=")
  signature
}

pub fn get_object_test() {
  let signed =
    base(http.Get, "/test.txt")
    |> request.set_header("range", "bytes=0-9")
    |> sigv4.sign([], credentials(), may_24_2013())
  assert signature_of(signed)
    == "f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41"
  let assert Ok(authorization) = request.get_header(signed, "authorization")
  assert string.contains(
    authorization,
    "SignedHeaders=host;range;x-amz-content-sha256;x-amz-date,",
  )
}

pub fn put_object_test() {
  let signed =
    base(http.Put, "/test%24file.text")
    |> request.set_header("date", "Fri, 24 May 2013 00:00:00 GMT")
    |> request.set_header("x-amz-storage-class", "REDUCED_REDUNDANCY")
    |> request.set_body(<<"Welcome to Amazon S3.":utf8>>)
    |> sigv4.sign([], credentials(), may_24_2013())
  assert signature_of(signed)
    == "98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd"
}

pub fn get_bucket_lifecycle_test() {
  let signed =
    base(http.Get, "/")
    |> sigv4.sign([#("lifecycle", "")], credentials(), may_24_2013())
  assert signature_of(signed)
    == "fea454ca298b7da1c68078a5d1bdbfbbe0d65c699e0f91ac7a200a0136783543"
  assert signed.query == Some("lifecycle=")
}

pub fn list_objects_test() {
  let signed =
    base(http.Get, "/")
    |> sigv4.sign(
      [#("max-keys", "2"), #("prefix", "J")],
      credentials(),
      may_24_2013(),
    )
  assert signature_of(signed)
    == "34b48302e7b5fa45bde8084f4b7868a86f0a534bc59db6670ed5711ef69dc6f7"
}

pub fn presigned_url_test() {
  let url =
    sigv4.presign(
      http.Get,
      http.Https,
      "examplebucket.s3.amazonaws.com",
      None,
      "/test.txt",
      [],
      credentials(),
      may_24_2013(),
      86_400,
    )
  assert string.ends_with(
    url,
    "&X-Amz-Signature=aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404",
  )
  assert string.starts_with(
    url,
    "https://examplebucket.s3.amazonaws.com/test.txt?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20130524%2Fus-east-1%2Fs3%2Faws4_request&X-Amz-Date=20130524T000000Z&X-Amz-Expires=86400&X-Amz-SignedHeaders=host",
  )
}

pub fn session_tokens_are_signed_test() {
  let credentials = sigv4.Credentials(..credentials(), session_token: Some("t"))
  let signed =
    base(http.Get, "/a") |> sigv4.sign([], credentials, may_24_2013())
  assert list.key_find(signed.headers, "x-amz-security-token") == Ok("t")
  let assert Ok(authorization) = request.get_header(signed, "authorization")
  assert string.contains(authorization, "x-amz-security-token")
}
