defmodule Adinize.HashTest do
  use ExUnit.Case, async: true
  doctest Adinize.Hash

  alias Adinize.Hash

  # Meta, Customer Information Parameters:
  # https://developers.facebook.com/docs/marketing-api/conversions-api/parameters/customer-information-parameters
  test "Meta's email example" do
    assert Hash.email("John_Smith@gmail.com") ==
             "62a14e44f765419d10fea99367361a727c12365e2520f32218d505ed9aa0f62f"
  end

  test "trims and lowercases an email" do
    assert Hash.email(" Jane@Example.com ") ==
             "8c87b489ce35cf2e2f39f80e282cb2e804932a56a213983eeeb428407d43b52d"
  end

  test "Meta's name examples, UTF-8 kept" do
    assert Hash.name("Mary") == "6915771be1c5aa0c886870b6951b03d7eafc121fea0e80a5ea83beb7c449f4ec"
    assert Hash.name("정") == "8fa8cd9c440be61d0151429310034083132b35975c4bea67fdd74158eb51db14"

    assert Hash.name("Valéry") ==
             "08e1996b5dd49e62a4b4c010d44e4345592a863bb9f8e3976219bac29417149c"
  end

  test "a street address is trimmed and lowercased" do
    assert Hash.street_address(" 1 Nile St ") == Hash.street_address("1 nile st")
  end

  test "phone_digits is nil for nil, blank and invalid UTF-8, and does not raise" do
    assert Hash.phone_digits(nil) == nil
    assert Hash.phone_digits("") == nil
    assert Hash.phone_digits(<<255, ?1>>) == nil
  end

  test "blank or missing input hashes to nil" do
    assert Hash.email("   ") == nil
    assert Hash.email(nil) == nil
    assert Hash.name("") == nil
  end
end
