defmodule Valea.Mail.HtmlSanitizerTest do
  use ExUnit.Case, async: true

  alias Valea.Mail.HtmlSanitizer

  # NOTE: `~s[...]` throughout, never `~s(...)` — sigil delimiters don't
  # nest, so a payload containing `alert(1)` would terminate a paren sigil
  # early and corrupt the parse of everything after it.

  describe "sanitize/1" do
    test "drops script/iframe/object/form/meta/link/base wholesale" do
      html = """
      <p>Hi</p>
      <script>alert(1)</script>
      <iframe src="https://evil.example"></iframe>
      <object data="x"></object><embed src="x">
      <form action="https://evil.example"><input name="a"><button>go</button></form>
      <base href="https://evil.example/">
      <meta http-equiv="refresh" content="0;url=https://evil.example">
      <link rel="stylesheet" href="https://evil.example/x.css">
      """

      out = HtmlSanitizer.sanitize(html)
      assert out =~ "<p>Hi</p>"

      for tag <- ~w(script iframe object embed form input button base meta link) do
        refute out =~ "<#{tag}"
      end
    end

    test "strips every on* handler attribute but keeps benign ones" do
      out =
        HtmlSanitizer.sanitize(
          ~s[<img src="https://x.example/a.png" onerror="alert(1)" alt="pic" width="10">]
        )

      refute out =~ "onerror"
      assert out =~ ~s[alt="pic"]
      assert out =~ ~s[src="https://x.example/a.png"]
    end

    test "drops javascript: URLs, including whitespace-obfuscated ones" do
      refute HtmlSanitizer.sanitize(~s[<a href="javascript:alert(1)">x</a>]) =~ "href"
      refute HtmlSanitizer.sanitize(~s[<a href="jav\tascript:alert(1)">x</a>]) =~ "href"
      refute HtmlSanitizer.sanitize(~s[<a href=" JaVaScRiPt:alert(1)">x</a>]) =~ "href"
      refute HtmlSanitizer.sanitize(~s[<img src="data:text/html,evil">]) =~ "src"
    end

    test "keeps http(s)/mailto/cid/data:image URLs and fragments" do
      html =
        ~s[<a href="https://ok.example">a</a><a href="mailto:x@y.z">b</a>] <>
          ~s[<img src="cid:logo"><img src="data:image/png;base64,AAAA"><a href="#top">c</a>]

      out = HtmlSanitizer.sanitize(html)
      assert out =~ ~s[href="https://ok.example"]
      assert out =~ ~s[href="mailto:x@y.z"]
      assert out =~ ~s[src="cid:logo"]
      assert out =~ ~s[src="data:image/png;base64,AAAA"]
      assert out =~ ~s[href="#top"]
    end

    test "keeps <style> blocks and style attributes (HTML mail is styled inline)" do
      out =
        HtmlSanitizer.sanitize(~s[<style>p{color:red}</style><p style="font-weight:bold">x</p>])

      assert out =~ "<style>"
      assert out =~ ~s[style="font-weight:bold"]
    end

    test "drops srcset/ping/formaction; invalid input bytes are scrubbed to valid UTF-8" do
      out =
        HtmlSanitizer.sanitize(
          ~s[<img src="https://x.example/a.png" srcset="https://t.example/a 1x">]
        )

      refute out =~ "srcset"
      assert String.valid?(HtmlSanitizer.sanitize(<<0xFF, 0xFE>>))
    end
  end

  describe "external_content?/1" do
    test "true for remote images and CSS url() loads; false for links and inline data" do
      assert HtmlSanitizer.external_content?(~s[<img src="https://t.example/pixel.gif">])

      assert HtmlSanitizer.external_content?(
               ~s[<div style="background:url('http://t.example/b.png')">x</div>]
             )

      refute HtmlSanitizer.external_content?(~s[<a href="https://ok.example">link</a>])
      refute HtmlSanitizer.external_content?(~s[<img src="data:image/png;base64,AAAA">])
      refute HtmlSanitizer.external_content?(~s[<img src="cid:logo">])
    end
  end
end
