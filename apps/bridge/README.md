## Install Aptos CLI

```
https://aptos.dev/tools/aptos-cli/install-cli/
```

## Initializing commands:

Initialize package with folder structure - To be done only else if the folder structure is not in place.

```
aptos move init --name propbase

```

Initialize admin address

```
aptos init --profile default
```

Initialize any wallet profile as follows

```
aptos init --profile admin
```

## Compile

Add the following line in Move.toml under [addresses]

```
propbase = "0x1"
```

Replace Line 164 with the following line

```
const PROPS_COIN: vector<u8> = b"0x1::propbase_coin::PROPS";
```

Run compile

```
aptos move compile --named-addresses source_addr=[default or any account's address]
```

```
aptos move compile  --named-addresses source_addr=87ab7d47a9b0ac84b856168b68fff06408cc5f1c691a6c5366c3ab116d76d93c --save-metadata
```

## Test

Test files are here at [propbase_staking_tests.move](https://github.com/Propbase-Application/propbase_staking_blockchain/tree/main/tests/propbase_staking_tests.move). Commands for testing are mentioned down below.

There is a [PROP.move](https://github.com/Propbase-Application/propbase_staking_blockchain/tree/main/sources/test/PROP.move) file with address 0x1 to mimick the $PROPS coin in test cases. Hence this 0x1 address needs to be hard coded in the contract and in Move.html for running tests.

Since the contract uses resource account, for testing the contract, we need to create a different resource address. This creates a situation where the signer capability are different for test mode and non-test mode. Hence some functions where signer capability are directly required as in init_module are not directly testable in test mode. Here we wont be able to achieve the test coverage.

Commands to run tests are as follows:

Add the following line in Move.toml under [addresses]

```
propbase = "0x1"
```

Replace Line 164 with the following line

```
const PROPS_COIN: vector<u8> = b"0x1::propbase_coin::PROPS";
```

Run Test

```
aptos move test --named-addresses source_addr=87ab7d47a9b0ac84b856168b68fff06408cc5f1c691a6c5366c3ab116d76d93c --ignore-compile-warnings
```

## Test Coverage Summary

Add the following line in Move.toml under [addresses]

```
propbase = "0x1"
```

Replace Line 164 with the following line

```
const PROPS_COIN: vector<u8> = b"0x1::propbase_coin::PROPS";
```

Run Test Coverage

```
aptos move test --coverage --named-addresses source_addr=87ab7d47a9b0ac84b856168b68fff06408cc5f1c691a6c5366c3ab116d76d93c --ignore-compile-warnings
```

## Function-wise Test Coverage Summary

Add the following line in Move.toml under [addresses]

```
propbase = "0x1"
```

Replace Line 164 with the following line

```
const PROPS_COIN: vector<u8> = b"0x1::propbase_coin::PROPS";
```

Run Function-wise Test Coverage

```
aptos move coverage summary --summarize-functions --named-addresses source_addr=12347d47a9b0ac564856168b68fff06408cc5f1c691yur5366c3ab116d76rsdf
```

## Achieved Test Coverage

```
Test result: OK. Total tests: 213; passed: 213; failed: 0
+-------------------------+
| Move Coverage Summary   |
+-------------------------+
Module 0000000000000000000000000000000000000000000000000000000000000001::propbase_staking
>>> % Module coverage: 94.98
+-------------------------+
| % Move Coverage: 94.98  |
+-------------------------+
```

## Publish via resource account in Testnet/Devnet

Make sure all local changes are reverted.
Replace line 164 with actual PROPS coin address

```
0xd8221ad202d71302027adab3706f9e8731b76b870bc1a163b0922ac5d91a905f::propbase_coin::TEST_PROPS
```

```
aptos move create-resource-account-and-publish-package --seed [seed] --address-name propbase --profile default --named-addresses source_addr=[default account's address]
```

## Publish via resource account in Mainnet

Make sure all local changes are reverted.
Replace line 164 with actual PROPS coin address

```
0xe50684a338db732d8fb8a3ac71c4b8633878bd0193bca5de2ebc852a83b35099::propbase_coin::PROPS
```

```
aptos move create-resource-account-and-publish-package --seed [seed] --address-name propbase --profile default --named-addresses source_addr=[default account's address] --included-artifacts none
```

## Example Function Invoking commands

<!-- aptos move publish --named-addresses props_bridge=0x87ab7d47a9b0ac84b856168b68fff06408cc5f1c691a6c5366c3ab116d76d93c
 -->

aptos move publish --named-addresses props_bridge=0xe38f07679dffc9290a7c2a2754aab66cec215a2d4d9d77270ca069195f3af592 --profile common_admin_5

```
aptos move create-resource-account-and-publish-package --seed 6000 --address-name propbase --named-addresses source_addr=87ab7d47a9b0ac84b856168b68fff06408cc5f1c691a6c5366c3ab116d76d93c --included-artifacts none --profile admin

```

Example of created resource account address

```
0xa4e7895b2708930b49e45e48f2e683e452b03da87c0eef2d949279883f39fe3f
```

```
aptos move run --function-id 0xa4e7895b2708930b49e45e48f2e683e452b03da87c0eef2d949279883f39fe3f::propbase_staking::set_admin --args address:0xb6a2004204ea1e64cbd1c43d9bbc3af5f3675ecc88d932aa019ddcebfbdbaab0
```

```
aptos move run --function-id 7g9aa29b11420032ar7ua577e6a33552060a887a21e4228b1cb687eb9cd22b34::propbase_staking::set_treasury --args address:0x746f4a1e6501f852bb31039ee1ec8d9e8be58a0193483d7168b4b21ad1ee5897
```

```
aptos move run --function-id 7g9aa29b11420032ar7ua577e6a33552060a887a21e4228b1cb687eb9cd22b34::propbase_staking::set_reward_treasurer --args address:0x746f4a1e6501f852bb31039ee1ec8d9e8be58a0193483d7168b4b21ad1ee5897
```
