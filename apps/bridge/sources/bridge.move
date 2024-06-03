module props_bridge::asset {
    struct USDC {}
    struct USDT {}
    struct BUSD {}
    struct USDD {}

    struct WETH {}
    struct WBTC {}
}

module props_bridge::coin_bridge {
    use std::error;
    use std::string;
    use std::vector;
    use std::signer::{address_of};

    use aptos_std::table::{Self, Table};
    use aptos_std::event::{Self, EventHandle};
    use aptos_std::type_info::{Self, TypeInfo};
    use aptos_std::from_bcs::to_address;
    use aptos_std::math64;
    use std::bcs;

    use aptos_framework::coin::{Self, BurnCapability, MintCapability, FreezeCapability, Coin};
    use aptos_framework::aptos_coin::AptosCoin;
    use aptos_framework::account;

    use layerzero_common::serde;
    use layerzero_common::utils::{vector_slice, assert_u16, assert_signer, assert_length};
    use layerzero::endpoint::{Self, UaCapability};
    use layerzero::lzapp;
    use layerzero::remote;
    use zro::zro::ZRO;
    use props_bridge::limiter;

    const EBRIDGE_UNREGISTERED_COIN: u64 = 0x00;
    const EBRIDGE_COIN_ALREADY_EXISTS: u64 = 0x01;
    const EBRIDGE_REMOTE_COIN_NOT_FOUND: u64 = 0x02;
    const EBRIDGE_INVALID_COIN_TYPE: u64 = 0x03;
    const EBRIDGE_CLAIMABLE_COIN_NOT_FOUND: u64 = 0x04;
    const EBRIDGE_INVALID_COIN_DECIMALS: u64 = 0x05;
    const EBRIDGE_COIN_NOT_UNWRAPPABLE: u64 = 0x06;
    const EBRIDGE_INSUFFICIENT_LIQUIDITY: u64 = 0x07;
    const EBRIDGE_INVALID_ADDRESS: u64 = 0x08;
    const EBRIDGE_INVALID_SIGNER: u64 = 0x09;
    const EBRIDGE_INVALID_PACKET_TYPE: u64 = 0x0a;
    const EBRIDGE_PAUSED: u64 = 0x0b;
    const EBRIDGE_SENDING_AMOUNT_TOO_FEW: u64 = 0x0c;
    const EBRIDGE_INVALID_ADAPTER_PARAMS: u64 = 0x0d;

    // paceket type, in line with EVM
    const PRECEIVE: u8 = 0;
    const PSEND: u8 = 1;

    const SHARED_DECIMALS: u8 = 6;

    const SEND_PAYLOAD_SIZE: u64 = 74;

    // layerzero user application generic type for this app
    struct BridgeUA {}

    struct FakeMoney {}

    struct Path has copy, drop {
        remote_chain_id: u64,
        remote_coin_addr: vector<u8>,
    }

    struct CoinTypeStore has key {
        type_lookup: Table<Path, TypeInfo>,
        types: vector<TypeInfo>,
    }

    struct LzCapability has key {
        cap: UaCapability<BridgeUA>
    }

    struct Config has key {
        paused_global: bool,
        paused_coins: Table<TypeInfo, bool>, // coin type -> paused
        custom_adapter_params: bool,
    }

    struct RemoteCoin has store, drop {
        remote_address: vector<u8>,
        // in shared decimals
        tvl_sd: u64,
        // whether the coin can be unwrapped into native coin on remote chain, like WETH -> ETH on ethereum, WBNB -> BNB on BSC
        unwrappable: bool,
    }

    struct CoinStore<phantom CoinType> has key {
        ld2sd_rate: u64,
        // chainId -> remote coin
        remote_coins: Table<u64, RemoteCoin>,
        // chain id of remote coins
        remote_chains: vector<u64>,
        claimable_amt_ld: Table<address, u64>,
        // coin caps
        mint_cap: MintCapability<FakeMoney>,
        burn_cap: BurnCapability<FakeMoney>,
        freeze_cap: FreezeCapability<FakeMoney>,
    }

    struct EventStore has key {
        send_events: EventHandle<SendEvent>,
        receive_events: EventHandle<ReceiveEvent>,
        claim_events: EventHandle<ClaimEvent>,
    }

    struct SendEvent has drop, store {
        coin_type: TypeInfo,
        dst_chain_id: u64,
        dst_receiver: vector<u8>,
        amount_ld: u64,
        unwrap: bool,
    }

    struct ReceiveEvent has drop, store {
        coin_type: TypeInfo,
        src_chain_id: u64,
        receiver: address,
        amount_ld: u64,
        stashed: bool,
    }

    struct ClaimEvent has drop, store {
        coin_type: TypeInfo,
        receiver: address,
        amount_ld: u64,
    }

    fun init_module(account: &signer) {
        let cap = endpoint::register_ua<BridgeUA>(account);
        lzapp::init(account, cap);
        remote::init(account);

        move_to(account, LzCapability { cap });

        move_to(account, Config {
            paused_global: false,
            paused_coins: table::new(),
            custom_adapter_params: false,
        });

        move_to(account, CoinTypeStore {
            type_lookup: table::new(),
            types: vector::empty(),
        });

        move_to(account, EventStore {
            send_events: account::new_event_handle<SendEvent>(account),
            receive_events: account::new_event_handle<ReceiveEvent>(account),
            claim_events: account::new_event_handle<ClaimEvent>(account),
        });
    }


    //  public fun initialize_and_register_fake_money(
    //     account: &signer,
    //     decimals: u8,
    //     monitor_supply: bool,
    // ): (BurnCapability<FakeMoney>, FreezeCapability<FakeMoney>, MintCapability<FakeMoney>) {
    //     let (burn_cap, freeze_cap, mint_cap) = initialize_fake_money(
    //         account,
    //         decimals,
    //         monitor_supply
    //     );
    //     create_coin_store<FakeMoney>(account);
    //     create_coin_conversion_map(account);
    //     (burn_cap, freeze_cap, mint_cap)
    // }

    // public entry fun create_fake_money(
    //     source: &signer,
    //     destination: &signer,
    //     amount: u64
    // ) acquires CoinInfo, CoinStore, CoinConversionMap {
    //     let (burn_cap, freeze_cap, mint_cap) = initialize_and_register_fake_money(source, 18, true);

    //     create_coin_store<FakeMoney>(destination);
    //     let coins_minted = mint<FakeMoney>(amount, &mint_cap);
    //     deposit(signer::address_of(source), coins_minted);
    //     move_to(source, FakeMoneyCapabilities {
    //         burn_cap,
    //         freeze_cap,
    //         mint_cap,
    //     });
    // }

    //
    // layerzero admin interface
    //
    // admin function to add coin to the bridge
    public entry fun register_coin<CoinType>(
        account: &signer,
        name: string::String,
        symbol: string::String,
        decimals: u8,
        limiter_cap_sd: u64
    ) acquires CoinTypeStore {
        assert_signer(account, @props_bridge);
        assert!(!has_coin_registered<CoinType>(), error::already_exists(EBRIDGE_COIN_ALREADY_EXISTS));
        assert!(SHARED_DECIMALS <= decimals, error::invalid_argument(EBRIDGE_INVALID_COIN_DECIMALS));

        // let (burn_cap, freeze_cap, mint_cap) = coin::initialize<CoinType>(account, name, symbol, decimals, true);

let (burn_cap, freeze_cap, mint_cap) = coin::initialize<FakeMoney>(account, name, symbol, decimals, true);

// initialize<FakeMoney>(
//             account,
//             string::utf8(b"Fake money"),
//             string::utf8(b"FMD"),
//             decimals,
//             monitor_supply
//         )

        let type_store = borrow_global_mut<CoinTypeStore>(@props_bridge);
        vector::push_back(&mut type_store.types, type_info::type_of<CoinType>());

        move_to(account, CoinStore<CoinType> {
            ld2sd_rate: math64::pow(10, ((decimals - SHARED_DECIMALS) as u64)),
            remote_coins: table::new(),
            remote_chains: vector::empty(),
            claimable_amt_ld: table::new(),
            mint_cap,
            burn_cap,
            freeze_cap
        });

        limiter::register_coin<CoinType>(account, limiter_cap_sd);
    }

    // admin function to configure TWA cap
    public entry fun set_limiter_cap<CoinType>(account: &signer, enabled: bool, cap_sd: u64, window_sec: u64) {
        assert_signer(account, @props_bridge);
        assert_registered_coin<CoinType>();

        limiter::set_limiter<CoinType>(enabled, cap_sd, window_sec)
    }


    // 0xea33def69b4bce19afe062e48581d9bc8d7b8d11e154c007a6325f2a45146b53::usdt::USDT
    // 108
    // [48,120,49,55,53,57,99,99,48,100,51,49,54,49,102,49,101,98,55,57,102,54,53,56,52,55,100,52,102,101,98,57]
    // false

    // 161
    // 0x9fa161D01526309dc7fca950463473cd2BD982C4 => [48,120,57,102,97,49,54,49,68,48,49,53,50,54,51,48,57,100,99,55,102,99,97,57,53,48,52,54,51,52,55,51]
    // false

    // 10102
    // 0x6Fcb97553D41516Cb228ac03FdC8B9a0a9df04A1 => [48,120,54,70,99,98,57,55,53,53,51,68,52,49,53,49,54,67,98,50,50,56,97,99,48,51,70,100,67,56,66,57]
    // false
    // one registered CoinType can have multiple remote coins, e.g. ETH-USDC and AVAX-USDC
    public entry fun set_remote_coin<CoinType>(
        account: &signer,
        remote_chain_id: u64,
        remote_coin_addr: vector<u8>,
        unwrappable: bool,
    ) acquires CoinStore, CoinTypeStore {
        assert_signer(account, @props_bridge);
        assert_u16(remote_chain_id);
        assert_length(&remote_coin_addr, 32);
        assert_registered_coin<CoinType>();

        let coin_store = borrow_global_mut<CoinStore<CoinType>>(@props_bridge);
        assert!(!table::contains(&coin_store.remote_coins, remote_chain_id), error::invalid_argument(EBRIDGE_COIN_ALREADY_EXISTS));

        let remote_coin = RemoteCoin {
            remote_address: remote_coin_addr,
            tvl_sd: 0,
            unwrappable,
        };
        table::add(&mut coin_store.remote_coins, remote_chain_id, remote_coin);
        vector::push_back(&mut coin_store.remote_chains, remote_chain_id);

        let type_store = borrow_global_mut<CoinTypeStore>(@props_bridge);
        table::add(&mut type_store.type_lookup, Path { remote_chain_id, remote_coin_addr }, type_info::type_of<CoinType>());
    }

    public entry fun set_global_pause(account: &signer, paused: bool) acquires Config {
        assert_signer(account, @props_bridge);

        let config = borrow_global_mut<Config>(@props_bridge);
        config.paused_global = paused;
    }

    public entry fun set_pause<CoinType>(account: &signer, paused: bool) acquires Config {
        assert_signer(account, @props_bridge);
        assert_registered_coin<CoinType>();

        let config = borrow_global_mut<Config>(@props_bridge);
        table::upsert(&mut config.paused_coins, type_info::type_of<CoinType>(), paused);
    }

    public entry fun enable_custom_adapter_params(account: &signer, enabled: bool) acquires Config {
        assert_signer(account, @props_bridge);

        let config = borrow_global_mut<Config>(@props_bridge);
        config.custom_adapter_params = enabled;
    }

    // public fun get_coin_capabilities<CoinType>(account: &signer): (MintCapability<CoinType>, BurnCapability<CoinType>, FreezeCapability<CoinType>) acquires CoinStore {
    //     assert_signer(account, @props_bridge);
    //     assert_registered_coin<CoinType>();

    //     let coin_store = borrow_global<CoinStore<CoinType>>(@props_bridge);
    //     (coin_store.mint_cap, coin_store.burn_cap, coin_store.freeze_cap)
    // }

    //
    // coin transfer functions
    //
    public fun send_coin<CoinType>(
        user: &signer,
        coin: Coin<CoinType>,
        dst_chain_id: u64,
        dst_receiver: vector<u8>,
        fee: Coin<AptosCoin>,
        unwrap: bool,
        adapter_params: vector<u8>,
        msglib_params: vector<u8>,
    ): Coin<AptosCoin> acquires CoinStore, EventStore, Config, LzCapability {
        let (native_refund, zro_refund) = send_coin_with_zro(user, coin, dst_chain_id, dst_receiver, fee, coin::zero<ZRO>(), unwrap, adapter_params, msglib_params);
        coin::destroy_zero(zro_refund);
        native_refund
    }

    public fun send_coin_with_zro<CoinType>(
        user: &signer,
        coin: Coin<CoinType>,
        dst_chain_id: u64,
        dst_receiver: vector<u8>,
        native_fee: Coin<AptosCoin>,
        zro_fee: Coin<ZRO>,
        unwrap: bool,
        adapter_params: vector<u8>,
        msglib_params: vector<u8>,
    ): (Coin<AptosCoin>, Coin<ZRO>) acquires CoinStore, EventStore, Config, LzCapability {
        let amount_ld = coin::value(&coin);
        let send_amount_ld = remove_dust_ld<CoinType>(coin::value(&coin));
        if (amount_ld > send_amount_ld) {
            // remove the dust and deposit into the bridge account
            let dust = coin::extract(&mut coin, amount_ld - send_amount_ld);
            coin::deposit(@props_bridge, dust);
            // coin::transfer(from_signer, receiver, 1);

        };
        let amount_ld = coin::value(&coin);
        let (native_refund, zro_refund) = send_coin_internal<CoinType>(user, coin, dst_chain_id, dst_receiver, native_fee, zro_fee, unwrap, adapter_params, msglib_params);

        (native_refund, zro_refund)
    }

    public entry fun send_coin_from<CoinType>(
        sender: &signer,
        dst_chain_id: u64,
        dst_receiver: vector<u8>,
        amount_ld: u64,
        native_fee: u64,
        zro_fee: u64,
        unwrap: bool,
        adapter_params: vector<u8>,
        msglib_params: vector<u8>,
    ) acquires CoinStore, EventStore, Config, LzCapability {
        let send_amt_ld = remove_dust_ld<CoinType>(amount_ld);
        let coin = coin::withdraw<CoinType>(sender, send_amt_ld);
        let native_fee = withdraw_coin_if_needed<AptosCoin>(sender, native_fee);
        let zro_fee = withdraw_coin_if_needed<ZRO>(sender, zro_fee);
        let amount_ld = coin::value(&coin);

        let (native_refund, zro_refund) = send_coin_internal<CoinType>(sender, coin, dst_chain_id, dst_receiver, native_fee, zro_fee, unwrap, adapter_params, msglib_params);

        // deposit back to sender
        let sender_addr = address_of(sender);
        deposit_coin_if_needed(sender_addr, native_refund);
        deposit_coin_if_needed(sender_addr, zro_refund);
    }

    fun send_coin_internal<CoinType>(
        sender: &signer,
        coin: Coin<CoinType>,
        dst_chain_id: u64,
        dst_receiver: vector<u8>,
        native_fee: Coin<AptosCoin>,
        zro_fee: Coin<ZRO>,
        unwrap: bool,
        adapter_params: vector<u8>,
        msglib_params: vector<u8>,
    ): (Coin<AptosCoin>, Coin<ZRO>) acquires CoinStore, EventStore, Config, LzCapability {
        assert_registered_coin<CoinType>();
        assert_unpaused<CoinType>();
        assert_u16(dst_chain_id);
        assert_length(&dst_receiver, 32);

        // assert that the remote coin is configured
        let coin_store = borrow_global_mut<CoinStore<CoinType>>(@props_bridge);
        assert!(table::contains(&coin_store.remote_coins, dst_chain_id), error::not_found(EBRIDGE_REMOTE_COIN_NOT_FOUND));

        // the dust value of the coin has been removed
        let amount_ld = coin::value(&coin);
        let amount_sd = ld2sd(amount_ld, coin_store.ld2sd_rate);
        assert!(amount_sd > 0, error::invalid_argument(EBRIDGE_SENDING_AMOUNT_TOO_FEW));

        // try to insert into the limiter. abort if overflowed
        limiter::try_insert<CoinType>(amount_sd);

        // assert remote chain has enough liquidity
        let remote_coin = table::borrow_mut(&mut coin_store.remote_coins, dst_chain_id);
        assert!(remote_coin.tvl_sd >= amount_sd, error::invalid_argument(EBRIDGE_INSUFFICIENT_LIQUIDITY));
        remote_coin.tvl_sd = remote_coin.tvl_sd - amount_sd;
        
        // burn the coin
        // coin::burn(coin, &coin_store.burn_cap);
        // let dust = coin::extract(&mut coin, amount_ld - 1);

        // coin::transfer<CoinType>(sender, @0x1, 1);
        coin::destroy_zero<CoinType>(coin);
        // lock

        // check gas limit with adapter params
        check_adapter_params(dst_chain_id, &adapter_params);

        // build payload
        if (unwrap) {
            assert!(remote_coin.unwrappable, error::invalid_argument(EBRIDGE_COIN_NOT_UNWRAPPABLE));
        };
        let payload = encode_send_payload(remote_coin.remote_address, dst_receiver, amount_sd, unwrap);

        // send lz msg to remote bridge
        let lz_cap = borrow_global<LzCapability>(@props_bridge);
        let dst_address = remote::get(@props_bridge, dst_chain_id);
        let (_, native_refund, zro_refund) = lzapp::send_with_zro<BridgeUA>(
            dst_chain_id,
            dst_address,
            payload,
            native_fee,
            zro_fee,
            adapter_params,
            msglib_params,
            &lz_cap.cap
        );

        // emit event
        let event_store = borrow_global_mut<EventStore>(@props_bridge);
        event::emit_event<SendEvent>(
            &mut event_store.send_events,
            SendEvent {
                coin_type: type_info::type_of<CoinType>(),
                dst_chain_id,
                dst_receiver,
                amount_ld,
                unwrap,
            },
        );

        (native_refund, zro_refund)
    }

    // 0xea33def69b4bce19afe062e48581d9bc8d7b8d11e154c007a6325f2a45146b53::usdt::USDT
    // 10102
    // 0x6Fcb97553D41516Cb228ac03FdC8B9a0a9df04A1 => [48,120,54,70,99,98,57,55,53,53,51,68,52,49,53,49,54,67,98,50,50,56,97,99,48,51,70,100,67,56,66,57]
    // [48,120,48,48,51,48,55,56,51,54,52,54,54,51,54,50,51,57,51,55,51,53,51,53,51,51,52,52,51,52,51,49,51,53,51,49,51,54,52,51,54,50,51,50,51,50,51,56,54,49,54,51,51,48,51,51,52,54,54,52,52,51,51,56,52,50,51,57,51,48,55,56,51]
    public entry fun lock_coins<CoinType>(src_chain_id: u64, src_address: vector<u8>, payload: vector<u8>) acquires Config, CoinStore  {
        assert_registered_coin<CoinType>();
        assert_unpaused<CoinType>();
        assert_u16(src_chain_id);

        // assert the payload is valid
        remote::assert_remote(@props_bridge, src_chain_id, src_address);

        // decode payload and get coin amount
        let (remote_coin_addr, receiver_bytes, amount_sd, packet_type) = decode_payload(&payload);
        assert!(packet_type == PSEND, error::aborted(EBRIDGE_INVALID_PACKET_TYPE));

        // assert remote_coin_addr
        let coin_store = borrow_global_mut<CoinStore<CoinType>>(@props_bridge);
        assert!(table::contains(&coin_store.remote_coins, src_chain_id), error::not_found(EBRIDGE_REMOTE_COIN_NOT_FOUND));
        let remote_coin = table::borrow_mut(&mut coin_store.remote_coins, src_chain_id);
        assert!(remote_coin_addr == remote_coin.remote_address, error::invalid_argument(EBRIDGE_INVALID_COIN_TYPE));

        // // add to tvl
        remote_coin.tvl_sd = remote_coin.tvl_sd + amount_sd;
    }


    // 161
    // 0x9fa161D01526309dc7fca950463473cd2BD982C4 => [48,120,57,102,97,49,54,49,68,48,49,53,50,54,51,48,57,100,99,55,102,99,97,57,53,48,52,54,51,52,55,51]


    // 0xea33def69b4bce19afe062e48581d9bc8d7b8d11e154c007a6325f2a45146b53::usdt::USDT
    // 108
    // [48,120,49,55,53,57,99,99,48,100,51,49,54,49,102,49,101,98,55,57,102,54,53,56,52,55,100,52,102,101,98,57]
    // [48,120,48,48,51,48,55,56,51,49,51,55,51,53,51,57,54,51,54,51,51,48,54,52,51,51,51,49,51,54,51,49,54,54,51,49,54,53,54,50,51,55,51,57,54,54,51,54,51,53,51,56,51,52,51,55,54,52,51,52,54,54,54,53,54,50,51,57,51,56,51,50,51]
    public entry fun lz_receive<CoinType>(src_chain_id: u64, src_address: vector<u8>, payload: vector<u8>) acquires EventStore, Config, LzCapability  { // CoinStore
        assert_registered_coin<CoinType>();
        assert_unpaused<CoinType>();
        assert_u16(src_chain_id);

        // assert the payload is valid
        remote::assert_remote(@props_bridge, src_chain_id, src_address);
        let lz_cap = borrow_global<LzCapability>(@props_bridge);
        endpoint::lz_receive<BridgeUA>(src_chain_id, src_address, payload, &lz_cap.cap);

        // decode payload and get coin amount
        // let (remote_coin_addr, receiver_bytes, amount_sd) = decode_receive_payload(&payload);

        // // assert remote_coin_addr
        // let coin_store = borrow_global_mut<CoinStore<CoinType>>(@props_bridge);
        // assert!(table::contains(&coin_store.remote_coins, src_chain_id), error::not_found(EBRIDGE_REMOTE_COIN_NOT_FOUND));
        // let remote_coin = table::borrow_mut(&mut coin_store.remote_coins, src_chain_id);
        // assert!(remote_coin_addr == remote_coin.remote_address, error::invalid_argument(EBRIDGE_INVALID_COIN_TYPE));

        // // add to tvl
        // remote_coin.tvl_sd = remote_coin.tvl_sd + amount_sd;

        // let amount_ld = sd2ld(amount_sd, coin_store.ld2sd_rate);

        // // stash if the receiver has not yet registered to receive the coin
        // let receiver = to_address(receiver_bytes);
        // let stashed = !coin::is_account_registered<CoinType>(receiver);
        // if (stashed) {
        //     let claimable_ld = table::borrow_mut_with_default(&mut coin_store.claimable_amt_ld, receiver, 0);
        //     *claimable_ld = *claimable_ld + amount_ld;
        // } else {
        //     let coins_minted = coin::mint(amount_ld, &coin_store.mint_cap);
        //     coin::deposit(receiver, coins_minted);
        // };

        // emit event
        let event_store = borrow_global_mut<EventStore>(@props_bridge);
        event::emit_event(
            &mut event_store.receive_events,
            ReceiveEvent {
                coin_type: type_info::type_of<CoinType>(),
                src_chain_id,
                receiver: @0x1,
                amount_ld: 0,
                stashed: false,
            }
        );
    }

    public entry fun claim_coin<CoinType>(receiver: &signer) acquires CoinStore, EventStore, Config {
        assert_registered_coin<CoinType>();
        assert_unpaused<CoinType>();

        // register the user if needed
        let receiver_addr = address_of(receiver);
        if (!coin::is_account_registered<CoinType>(receiver_addr)) {
            coin::register<CoinType>(receiver);
        };

        // assert the receiver has receivable and it is more than 0
        let coin_store = borrow_global_mut<CoinStore<CoinType>>(@props_bridge);
        assert!(table::contains(&coin_store.claimable_amt_ld, receiver_addr), error::not_found(EBRIDGE_CLAIMABLE_COIN_NOT_FOUND));
        let claimable_ld = table::remove(&mut coin_store.claimable_amt_ld, receiver_addr);
        assert!(claimable_ld > 0, error::not_found(EBRIDGE_CLAIMABLE_COIN_NOT_FOUND));

        // let coins_minted = coin::mint(claimable_ld, &coin_store.mint_cap);
        // coin::deposit(receiver_addr, coins_minted);

        // emit event
        let event_store = borrow_global_mut<EventStore>(@props_bridge);
        event::emit_event(
            &mut event_store.claim_events,
            ClaimEvent {
                coin_type: type_info::type_of<CoinType>(),
                receiver: receiver_addr,
                amount_ld: claimable_ld,
            }
        );
    }

    //
    // public view functions
    //
    #[view]
    public fun lz_receive_types(src_chain_id: u64, _src_address: vector<u8>, payload: vector<u8>): vector<TypeInfo> acquires CoinTypeStore {
        let (remote_coin_addr, _receiver, _amount) = decode_receive_payload(&payload);
        let path = Path { remote_chain_id: src_chain_id, remote_coin_addr };

        let type_store = borrow_global<CoinTypeStore>(@props_bridge);
        let coin_type_info = table::borrow(&type_store.type_lookup, path);

        vector::singleton<TypeInfo>(*coin_type_info)
    }

    #[view]
    public fun has_coin_registered<CoinType>(): bool {
        exists<CoinStore<CoinType>>(@props_bridge)
    }

    #[view]
    public fun quote_fee(dst_chain_id: u64, pay_in_zro: bool, adapter_params: vector<u8>, msglib_params: vector<u8>): (u64, u64) {
        endpoint::quote_fee(@props_bridge, dst_chain_id, SEND_PAYLOAD_SIZE, pay_in_zro, adapter_params, msglib_params)
    }

    #[view]
    public fun get_tvls_sd<CoinType>(): (vector<u64>, vector<u64>) acquires CoinStore {
        assert_registered_coin<CoinType>();
        let coin_store = borrow_global<CoinStore<CoinType>>(@props_bridge);
        let tvls = vector::empty<u64>();
        let i = 0;
        while (i < vector::length(&coin_store.remote_chains)) {
            let remote_chain_id = vector::borrow(&coin_store.remote_chains, i);
            let remote_coin = table::borrow(&coin_store.remote_coins, *remote_chain_id);
            vector::push_back(&mut tvls, remote_coin.tvl_sd);
            i = i + 1;
        };
        (coin_store.remote_chains, tvls)
    }

    public fun remove_dust_ld<CoinType>(amount_ld: u64): u64 acquires CoinStore {
        let coin_store = borrow_global<CoinStore<CoinType>>(@props_bridge);
        amount_ld / coin_store.ld2sd_rate * coin_store.ld2sd_rate
    }

    public fun is_valid_remote_coin<CoinType>(remote_chain_id: u64, remote_coin_addr: vector<u8>): bool acquires CoinStore {
        let coin_store = borrow_global<CoinStore<CoinType>>(@props_bridge);
        let remote_coin = table::borrow(&coin_store.remote_coins, remote_chain_id);
        remote_coin_addr == remote_coin.remote_address
    }

    //
    // internal functions
    //
    fun withdraw_coin_if_needed<CoinType>(account: &signer, amount_ld: u64): Coin<CoinType> {
        if (amount_ld > 0) {
            coin::withdraw<CoinType>(account, amount_ld)
        } else {
            coin::zero<CoinType>()
        }
    }

    fun deposit_coin_if_needed<CoinType>(account: address, coin: Coin<CoinType>) {
        if (coin::value(&coin) > 0) {
            coin::deposit(account, coin);
        } else {
            coin::destroy_zero(coin);
        }
    }

    // ld = local decimal. sd = shared decimal among all chains
    fun ld2sd(amount_ld: u64, ld2sd_rate: u64): u64 {
        amount_ld / ld2sd_rate
    }

    fun sd2ld(amount_sd: u64, ld2sd_rate: u64): u64 {
        amount_sd * ld2sd_rate
    }

    // encode payload: packet type(1) + remote token(32) + receiver(32) + amount(8) + unwarp flag(1)
    fun encode_send_payload(dst_coin_addr: vector<u8>, dst_receiver: vector<u8>, amount_sd: u64, unwrap: bool): vector<u8> {
        assert_length(&dst_coin_addr, 32);
        assert_length(&dst_receiver, 32);

        let payload = vector::empty<u8>();
        serde::serialize_u8(&mut payload, PSEND);
        serde::serialize_vector(&mut payload, dst_coin_addr);
        serde::serialize_vector(&mut payload, dst_receiver);
        serde::serialize_u64(&mut payload, amount_sd);
        let unwrap = if (unwrap) { 1 } else { 0 };
        serde::serialize_u8(&mut payload, unwrap);
        payload
    }

    // decode payload: packet type(1) + remote token(32) + receiver(32) + amount(8)
    fun decode_receive_payload(payload: &vector<u8>): (vector<u8>, vector<u8>, u64) {
        assert_length(payload, 73);

        let packet_type = serde::deserialize_u8(&vector_slice(payload, 0, 1));
        assert!(packet_type == PRECEIVE, error::aborted(EBRIDGE_INVALID_PACKET_TYPE));

        let remote_coin_addr = vector_slice(payload, 1, 33);
        let receiver_bytes = vector_slice(payload, 33, 65);
        let amount_sd = serde::deserialize_u64(&vector_slice(payload, 65, 73));
        (remote_coin_addr, receiver_bytes, amount_sd)
    }

    // decode payload: packet type(1) + remote token(32) + receiver(32) + amount(8)
    fun decode_payload(payload: &vector<u8>): (vector<u8>, vector<u8>, u64, u64) {
        assert_length(payload, 73);

        let packet_type = serde::deserialize_u8(&vector_slice(payload, 0, 1));
        let remote_coin_addr = vector_slice(payload, 1, 33);
        let receiver_bytes = vector_slice(payload, 33, 65);
        let amount_sd = serde::deserialize_u64(&vector_slice(payload, 65, 73));
        (remote_coin_addr, receiver_bytes, amount_sd, packet_type)
    }

    fun check_adapter_params(dst_chain_id: u64, adapter_params: &vector<u8>) acquires Config {
        let config = borrow_global<Config>(@props_bridge);
        if (config.custom_adapter_params) {
            lzapp::assert_gas_limit(@props_bridge, dst_chain_id,  (PSEND as u64), adapter_params, 0);
        } else {
            assert!(vector::is_empty(adapter_params), error::invalid_argument(EBRIDGE_INVALID_ADAPTER_PARAMS));
        }
    }

    fun assert_registered_coin<CoinType>() {
        assert!(has_coin_registered<CoinType>(), error::permission_denied(EBRIDGE_UNREGISTERED_COIN));
    }

    fun assert_unpaused<CoinType>() acquires Config {
        let config = borrow_global<Config>(@props_bridge);
        assert!(!config.paused_global, error::unavailable(EBRIDGE_PAUSED));

        let coin_type = type_info::type_of<CoinType>();
        if (table::contains(&config.paused_coins, coin_type)) {
            assert!(!*table::borrow(&config.paused_coins, coin_type), error::unavailable(EBRIDGE_PAUSED));
        }
    }


    // decode payload: packet type(1) + remote token(32) + receiver(32) + amount(8)

    #[view]
    public fun build_receive_coin_payload(src_coin_addr: vector<u8>, receiver: vector<u8>, amount: u64): vector<u8> {
        let payload = vector::empty<u8>();
        serde::serialize_u8(&mut payload, 0); // packet type: receive
        serde::serialize_vector(&mut payload, src_coin_addr);
        serde::serialize_vector(&mut payload, receiver);
        serde::serialize_u64(&mut payload, amount);
        payload
    }

    // bnb usdt  deploy
    // 0x4Aed70Ca724C2c268A4047A89A5d0Ee5Ee3D92ce => [48,120,52,65,101,100,55,48,67,97,55,50,52,67,50,99,50,54,56,65,52,48,52,55,65,56,57,65,53,100,48,69]
    #[view]
    public fun build_encode_payload_for_send(
        token_addr_bytes: vector<u8>, // remote coin address
        receiver_bytes: vector<u8>, // remote receiver
        amount: u8
    ): vector<u8> {
        let payload = vector<u8>[1]; // send packet type
        vector::append(&mut payload, token_addr_bytes); // remote coin address
        vector::append(&mut payload, receiver_bytes); // remote receiver
        vector::append(&mut payload, vector<u8>[0, 0, 0, 0, 0, 0, 0, amount, 1]); // amount + unwrap flag
        payload
    }

    #[view]
    public fun to_bytes(addr: address): vector<u8> {
        bcs::to_bytes(&addr)
    }



    //
    // uint tests
    //
//     #[test_only]
//     use std::bcs;

//     #[test_only]
//     struct AptosCoinCap has key {
//         mint_cap: MintCapability<AptosCoin>,
//         burn_cap: BurnCapability<AptosCoin>,
//     }

//     #[test_only]
    // public fun build_receive_coin_payload(src_coin_addr: vector<u8>, receiver: vector<u8>, amount: u64): vector<u8> {
    //     let payload = vector::empty<u8>();
    //     serde::serialize_u8(&mut payload, 0); // packet type: receive
    //     serde::serialize_vector(&mut payload, src_coin_addr);
    //     serde::serialize_vector(&mut payload, receiver);
    //     serde::serialize_u64(&mut payload, amount);
    //     payload
    // }

//     #[test]
//     fun test_encode_payload_for_send() {
//         let token_address = @0x10;
//         let receive = @0x11;
//         let token_addr_bytes = bcs::to_bytes(&token_address);
//         let receiver_bytes = bcs::to_bytes(&receive);
//         let actual = encode_send_payload(
//             token_addr_bytes,
//             receiver_bytes,
//             100,
//             true
//         );
//         let expected = vector<u8>[1]; // send packet type
//         vector::append(&mut expected, token_addr_bytes); // remote coin address
//         vector::append(&mut expected, receiver_bytes); // remote receiver
//         vector::append(&mut expected, vector<u8>[0, 0, 0, 0, 0, 0, 0, 100, 1]); // amount + unwrap flag
//         assert!(actual == expected, 0);
//     }

//     #[test]
//     fun test_decode_payload_for_receive() {
//         // payload got from evm birdge
//         let payload = x"0000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000002000000e8d4a51000";
//         let (remote_coin_addr, receiver, amount) = decode_receive_payload(&payload);
//         assert!(remote_coin_addr == x"0000000000000000000000000000000000000000000000000000000000000001", 0);
//         assert!(receiver == x"0000000000000000000000000000000000000000000000000000000000000002", 0);
//         assert!(amount == 1000000 * 1000000, 0);
//     }

//     #[test_only]
//     use props_bridge::asset::{USDC, WETH};
//     #[test_only]
//     use layerzero::test_helpers;
//     #[test_only]
//     use aptos_framework::timestamp;
//     #[test_only]
//     use std::hash::sha3_256;

//     #[test(aptos = @aptos_framework, layerzero_root = @layerzero, msglib_auth_root = @msglib_auth, bridge_root = @props_bridge, oracle_root = @1234, relayer_root = @5678, executor_root = @1357, executor_auth_root = @executor_auth)]
//     fun test_get_coin_capabilities(aptos: &signer, layerzero_root: &signer, msglib_auth_root: &signer, bridge_root: &signer, oracle_root: &signer, relayer_root: &signer, executor_root: &signer, executor_auth_root: &signer) acquires CoinTypeStore, CoinStore {
//         use aptos_framework::aptos_account;

//         timestamp::set_time_has_started_for_testing(aptos);

//         aptos_account::create_account(address_of(layerzero_root));
//         aptos_account::create_account(address_of(bridge_root));
//         aptos_account::create_account(address_of(oracle_root));
//         aptos_account::create_account(address_of(relayer_root));
//         aptos_account::create_account(address_of(executor_root));

//         test_helpers::setup_layerzero_for_test(layerzero_root, msglib_auth_root, oracle_root, relayer_root, executor_root, executor_auth_root,20030, 20030);

//         init_module(bridge_root);
//         register_coin<USDC>(bridge_root, string::utf8(b"USDC"), string::utf8(b"USDC"), 6, 10000000000000);

//         // get once
//         let (mint_cap, burn_cap, freeze_cap) = get_coin_capabilities<USDC>(bridge_root);
//         coin::destroy_mint_cap(mint_cap);
//         coin::destroy_burn_cap(burn_cap);
//         coin::destroy_freeze_cap(freeze_cap);

//         // get twice
//         let (mint_cap, burn_cap, freeze_cap) = get_coin_capabilities<USDC>(bridge_root);
//         coin::destroy_mint_cap(mint_cap);
//         coin::destroy_burn_cap(burn_cap);
//         coin::destroy_freeze_cap(freeze_cap);
//     }

//     #[test_only]
//     public fun init_module_for_test(creator: &signer) {
//         init_module(creator);
//     }

//     #[test_only]
//     fun setup(aptos: &signer, core_resources: &signer, layerzero_root: &signer, msglib_auth_root: &signer, bridge_root: &signer, oracle_root: &signer, relayer_root: &signer, executor_root: &signer, executor_auth_root: &signer, alice: &signer) {
//         use aptos_framework::aptos_account;
//         use aptos_framework::aptos_coin;

//         let core_resources_addr = address_of(core_resources);
//         let layerzero_root_addr = address_of(layerzero_root);
//         let msglib_auth_root_addr = address_of(msglib_auth_root);
//         let oracle_root_addr = address_of(oracle_root);
//         let relayer_root_addr = address_of(relayer_root);
//         let executor_root_addr = address_of(executor_root);
//         let executor_auth_root_addr = address_of(executor_auth_root);
//         let bridge_root_addr = address_of(bridge_root);
//         let alice_addr = address_of(alice);

//         // init the aptos_coin and give counter_root the mint ability.
//         let (burn_cap, mint_cap) = aptos_coin::initialize_for_test(aptos);

//         timestamp::set_time_has_started_for_testing(aptos);

//         aptos_account::create_account(core_resources_addr);
//         let coins = coin::mint<AptosCoin>(
//             18446744073709551615,
//             &mint_cap,
//         );
//         coin::deposit<AptosCoin>(address_of(core_resources), coins);

//         aptos_account::transfer(core_resources, layerzero_root_addr, 100000000000);
//         aptos_account::transfer(core_resources, msglib_auth_root_addr, 100000000000);
//         aptos_account::transfer(core_resources, oracle_root_addr, 100000000000);
//         aptos_account::transfer(core_resources, relayer_root_addr, 100000000000);
//         aptos_account::transfer(core_resources, executor_root_addr, 100000000000);
//         aptos_account::transfer(core_resources, executor_auth_root_addr, 100000000000);
//         aptos_account::transfer(core_resources, bridge_root_addr, 100000000000);
//         aptos_account::transfer(core_resources, alice_addr, 100000000000);

//         move_to(layerzero_root, AptosCoinCap {
//             mint_cap,
//             burn_cap
//         });
//     }

    #[test(aptos = @aptos_framework, core_resources = @core_resources, layerzero_root = @layerzero, msglib_auth_root = @msglib_auth, bridge_root = @props_bridge, oracle_root = @1234, relayer_root = @5678, executor_root = @1357, executor_auth_root = @executor_auth, alice = @0xABCD)]
    public entry fun test_send_and_receive_coin(aptos: &signer, core_resources: &signer, layerzero_root: &signer, msglib_auth_root: &signer, bridge_root: &signer, oracle_root: &signer, relayer_root: &signer, executor_root: &signer, executor_auth_root: &signer, alice: &signer) acquires EventStore, CoinStore, CoinTypeStore, Config, LzCapability {
        use layerzero::uln_config;
        use layerzero::test_helpers;
        use layerzero_common::packet;

        setup(aptos, core_resources, layerzero_root, msglib_auth_root, bridge_root, oracle_root, relayer_root, executor_root, executor_auth_root, alice);

        let alice_addr = address_of(alice);
        let alice_addr_bytes = bcs::to_bytes(&alice_addr);

        // prepare the endpoint
        let local_chain_id: u64 = 20030; // 108 aptos
        let remote_chain_id: u64 = 20030; // 161 sepolia
        test_helpers::setup_layerzero_for_test(layerzero_root, msglib_auth_root, oracle_root, relayer_root, executor_root, executor_auth_root, local_chain_id, remote_chain_id);
        // assumes layerzero is already initialized
        init_module(bridge_root);

        // config bridge
        let local_bridge_addr = @props_bridge;
        let remote_bridge_addr = @props_bridge;
        let remote_bridge_addr_bytes = bcs::to_bytes(&remote_bridge_addr);
        let local_bridge_addr_bytes = bcs::to_bytes(&local_bridge_addr);
        remote::set(bridge_root, remote_chain_id, remote_bridge_addr_bytes);

        let confirmations_bytes = vector::empty();
        serde::serialize_u64(&mut confirmations_bytes, 20);
        lzapp::set_config<BridgeUA>(bridge_root, 1, 0, remote_chain_id, 3, confirmations_bytes);
        let config = uln_config::get_uln_config(@props_bridge, remote_chain_id);
        assert!(uln_config::oracle(&config) == address_of(oracle_root), 0);
        assert!(uln_config::relayer(&config) == address_of(relayer_root), 0);
        assert!(uln_config::inbound_confirmations(&config) == 15, 0);
        assert!(uln_config::outbound_confiramtions(&config) == 20, 0);

        // config coin
        let decimals = 8;
        let rate = 100; // (8 - 6) ** 10
        register_coin<USDC>(bridge_root, string::utf8(b"USDC"), string::utf8(b"USDC"), decimals, 1000000000000);
        let remote_coin_addr = @props_bridge;
        let remote_coin_addr_bytes = bcs::to_bytes(&remote_coin_addr);
        //   const bytes = Buffer.alloc(
        //     32,
        //     '0x1759cc0d3161f1eb79f65847d4feb9d1f74fb79014698a23b16b28b9cd4c37e3'
        //   );

        //   console.log('bytes =======');
        //   console.log(bytes);

        //   const bytes32 = new Uint32Array(bytes);

        //   console.log('bytes32 =======');
        //   console.log(bytes32);
        // remote_coin_addr_bytes = bytes32



        // 161
        // 0x9fa161D01526309dc7fca950463473cd2BD982C4 => [48,120,57,102,97,49,54,49,68,48,49,53,50,54,51,48,57,100,99,55,102,99,97,57,53,48,52,54,51,52,55,51]
        // false
        set_remote_coin<USDC>(bridge_root, remote_chain_id, remote_coin_addr_bytes, false);
        let coin_store = borrow_global<CoinStore<USDC>>(local_bridge_addr);
        assert!(coin_store.remote_chains == vector<u64>[remote_chain_id], 0);
        assert!(remote_coin_addr_bytes == table::borrow(&coin_store.remote_coins, remote_chain_id).remote_address, 0);
        let type_store = borrow_global<CoinTypeStore>(local_bridge_addr);
        assert!(type_store.types == vector<TypeInfo>[type_info::type_of<USDC>()], 0);
        let coin_type_info = table::borrow(&type_store.type_lookup, Path { remote_chain_id, remote_coin_addr: remote_coin_addr_bytes });
        assert!(@props_bridge == type_info::account_address(coin_type_info), 0);
        assert!(b"asset" == type_info::module_name(coin_type_info), 0);
        assert!(b"USDC" == type_info::struct_name(coin_type_info), 0);

        // mock packet for receiving coin: remote chain -> local chain
        let nonce = 1;
        let amount_sd = 100000000000;

        



        // [48,120,49,55,53,57,99,99,48,100,51,49,54,49,102,49,101,98,55,57,102,54,53,56,52,55,100,52,102,101,98,57]
        // [56,50,50,49,97,100,50,48,50,100,55,49,51,48,50,48,50,55,97,100,97,98,51,55,48,54,102,57,101]
        // 1000000
        // 0x003078313735396363306433313631663165623739663635383437643466656239383232316164323032643731333032303237616461623337303666396500000000000f4240
        
        
        
        // [48,120,55,99,97,99,66,101,52,51,57,69,97,68,53,53,102,97,49,99,50,50,55,57,48,51,51,48,98,49,50,56]
        // 0x4Aed70Ca724C2c268A4047A89A5d0Ee5Ee3D92ce => [48,120,52,65,101,100,55,48,67,97,55,50,52,67,50,99,50,54,56,65,52,48,52,55,65,56,57,65,53,100,48,69]
        // 1000000
        // 0x003078376361634265343339456144353566613163323237393033333062313238307834416564373043613732344332633236384134303437413839413564304500000000000f4240
        // [48,120,48,48,51,48,55,56,51,55,54,51,54,49,54,51,52,50,54,53,51,52,51,51,51,57,52,53,54,49,52,52,51,53,51,53,54,54,54,49,51,49,54,51,51,50,51,50,51,55,51,57,51,48,51,51,51,51,51,48,54,50,51,49,51,50,51,56,51,48,55,56,51]
        
        
        // 0x6Fcb97553D41516Cb228ac03FdC8B9a0a9df04A1 => [48,120,54,70,99,98,57,55,53,53,51,68,52,49,53,49,54,67,98,50,50,56,97,99,48,51,70,100,67,56,66,57]
        // 0x4Aed70Ca724C2c268A4047A89A5d0Ee5Ee3D92ce => [48,120,52,65,101,100,55,48,67,97,55,50,52,67,50,99,50,54,56,65,52,48,52,55,65,56,57,65,53,100,48,69]
        // 1000000
        // 0x003078364663623937353533443431353136436232323861633033466443384239307834416564373043613732344332633236384134303437413839413564304500000000000f4240
        let payload = build_receive_coin_payload(remote_bridge_addr_bytes, alice_addr_bytes, amount_sd);
        // let emitted_packet = packet::new_packet(remote_chain_id, remote_bridge_addr_bytes, local_chain_id, local_bridge_addr_bytes, nonce, payload);

        // let lz_type = vector::borrow(&lz_receive_types(
        //     remote_chain_id,
        //     remote_bridge_addr_bytes,
        //     payload
        // ), 0);
        // assert!(@props_bridge == type_info::account_address(lz_type), 0);
        // assert!(b"asset" == type_info::module_name(lz_type), 0);
        // assert!(b"USDC" == type_info::struct_name(lz_type), 0);

        // test_helpers::deliver_packet<BridgeUA>(oracle_root, relayer_root, emitted_packet, 20);

        // receive coin but dont get the coin for no registering
        let expected_tvl = amount_sd;
        let expected_balance = sd2ld(amount_sd, rate);


    // 0xea33def69b4bce19afe062e48581d9bc8d7b8d11e154c007a6325f2a45146b53::usdt::USDT
    // 108
    // [48,120,49,55,53,57,99,99,48,100,51,49,54,49,102,49,101,98,55,57,102,54,53,56,52,55,100,52,102,101,98,57]
    // [48,120,48,48,51,48,55,56,51,49,51,55,51,53,51,57,54,51,54,51,51,48,54,52,51,51,51,49,51,54,51,49,54,54,51,49,54,53,54,50,51,55,51,57,54,54,51,54,51,53,51,56,51,52,51,55,54,52,51,52,54,54,54,53,54,50,51,57,51,56,51,50,51]
    // public entry fun lz_receive<CoinType>(src_chain_id: u64, src_address: vector<u8>, payload: vector<u8>) 


    // 0xea33def69b4bce19afe062e48581d9bc8d7b8d11e154c007a6325f2a45146b53::usdt::USDT
    // 161
    // [48,120,55,99,97,99,66,101,52,51,57,69,97,68,53,53,102,97,49,99,50,50,55,57,48,51,51,48,98,49,50,56] // [48,120,49,55,53,57,99,99,48,100,51,49,54,49,102,49,101,98,55,57,102,54,53,56,52,55,100,52,102,101,98,57]
    // [48,120,48,48,51,48,55,56,51,55,54,51,54,49,54,51,52,50,54,53,51,52,51,51,51,57,52,53,54,49,52,52,51,53,51,53,54,54,54,49,51,49,54,51,51,50,51,50,51,55,51,57,51,48,51,51,51,51,51,48,54,50,51,49,51,50,51,56,51,48,55,56,51]
    
    
    
    // 0x9fa161D01526309dc7fca950463473cd2BD982C4 => [48,120,57,102,97,49,54,49,68,48,49,53,50,54,51,48,57,100,99,55,102,99,97,57,53,48,52,54,51,52,55,51]



        // // 10102
        // // 0x6Fcb97553D41516Cb228ac03FdC8B9a0a9df04A1 => [48,120,54,70,99,98,57,55,53,53,51,68,52,49,53,49,54,67,98,50,50,56,97,99,48,51,70,100,67,56,66,57]
        // // [48,120,48,48,51,48,55,56,51,54,52,54,54,51,54,50,51,57,51,55,51,53,51,53,51,51,52,52,51,52,51,49,51,53,51,49,51,54,52,51,54,50,51,50,51,50,51,56,54,49,54,51,51,48,51,51,52,54,54,52,52,51,51,56,52,50,51,57,51,48,55,56,51]
        // lz_receive<USDC>(remote_chain_id, remote_bridge_addr_bytes, payload);
        // assert!(!coin::is_account_registered<USDC>(alice_addr), 0);
        // let coin_store = borrow_global<CoinStore<USDC>>(local_bridge_addr);
        // assert!(table::borrow(&coin_store.remote_coins, remote_chain_id).tvl_sd == expected_tvl, 0);

        // claim_coin<USDC>(alice);
        // let balance = coin::balance<USDC>(alice_addr);
        // assert!(balance == expected_balance, 0);

        // send coin: local chain -> remote chain
        let adapter_params = vector::empty<u8>();
        let msglib_params = vector::empty<u8>();
        let half_amount = expected_balance / 2;


        // bnb usdt  deploy
        // 0x4Aed70Ca724C2c268A4047A89A5d0Ee5Ee3D92ce => [48,120,52,65,101,100,55,48,67,97,55,50,52,67,50,99,50,54,56,65,52,48,52,55,65,56,57,65,53,100,48,69]
        build_encode_payload_for_send(
            token_addr_bytes: vector<u8>, // remote coin address
            receiver_bytes: vector<u8>, // remote receiver
            amount: u8
        )

        // 0xea33def69b4bce19afe062e48581d9bc8d7b8d11e154c007a6325f2a45146b53::usdt::USDT
        // 10102
        // 0x6Fcb97553D41516Cb228ac03FdC8B9a0a9df04A1 => [48,120,54,70,99,98,57,55,53,53,51,68,52,49,53,49,54,67,98,50,50,56,97,99,48,51,70,100,67,56,66,57]
        // [48,120,48,48,51,48,55,56,51,54,52,54,54,51,54,50,51,57,51,55,51,53,51,53,51,51,52,52,51,52,51,49,51,53,51,49,51,54,52,51,54,50,51,50,51,50,51,56,54,49,54,51,51,48,51,51,52,54,54,52,52,51,51,56,52,50,51,57,51,48,55,56,51]
        lock_coins<CoinType>(src_chain_id, src_address, payload);


        // 10102
        // false
        // []
        // []
        // fee = 23384782
        let (fee, _) = quote_fee(remote_chain_id, false, adapter_params, msglib_params);
        
        
        // 0xea33def69b4bce19afe062e48581d9bc8d7b8d11e154c007a6325f2a45146b53::usdt::USDT
        // 10102
        // 0x4Aed70Ca724C2c268A4047A89A5d0Ee5Ee3D92ce => [48,120,52,65,101,100,55,48,67,97,55,50,52,67,50,99,50,54,56,65,52,48,52,55,65,56,57,65,53,100,48,69]
        // 1000000
        // 23384782
        // 0
        // false
        // []
        // []
        send_coin_from<USDC>(alice, remote_chain_id, alice_addr_bytes, half_amount, fee, 0, false, adapter_params, msglib_params);
        let balance = coin::balance<USDC>(alice_addr);
        assert!(balance == half_amount, 0);
        let coin_store = borrow_global<CoinStore<USDC>>(local_bridge_addr);
        assert!(table::borrow(&coin_store.remote_coins, remote_chain_id).tvl_sd == expected_tvl / 2, 0);
    }

//     #[test(aptos = @aptos_framework, core_resources = @core_resources, layerzero_root = @layerzero, msglib_auth_root = @msglib_auth, bridge_root = @props_bridge, oracle_root = @1234, relayer_root = @5678, executor_root = @1357, executor_auth_root = @executor_auth, alice = @0xABCD)]
//     #[expected_failure(abort_code = 0x10003, location = Self)]
//     public entry fun test_receive_with_invalid_cointype(aptos: &signer, core_resources: &signer, layerzero_root: &signer, msglib_auth_root: &signer, bridge_root: &signer, oracle_root: &signer, relayer_root: &signer, executor_root: &signer, executor_auth_root: &signer, alice: &signer) acquires EventStore, CoinStore, CoinTypeStore, Config, LzCapability {
//         use layerzero::test_helpers;
//         use layerzero_common::packet;

//         setup(aptos, core_resources, layerzero_root, msglib_auth_root, bridge_root, oracle_root, relayer_root, executor_root, executor_auth_root, alice);

//         let alice_addr = address_of(alice);
//         let alice_addr_bytes = bcs::to_bytes(&alice_addr);

//         // prepare the endpoint
//         let local_chain_id: u64 = 20030;
//         let remote_chain_id: u64 = 20030;
//         test_helpers::setup_layerzero_for_test(layerzero_root, msglib_auth_root, oracle_root, relayer_root, executor_root, executor_auth_root, local_chain_id, remote_chain_id);
//         // assumes layerzero is already initialized
//         init_module(bridge_root);

//         // config bridge
//         let local_bridge_addr = @props_bridge;
//         let remote_bridge_addr = @props_bridge;
//         let remote_bridge_addr_bytes = bcs::to_bytes(&remote_bridge_addr);
//         let local_bridge_addr_bytes = bcs::to_bytes(&local_bridge_addr);
//         remote::set(bridge_root, remote_chain_id, remote_bridge_addr_bytes);

//         // config coin
//         let decimals = 8;
//         register_coin<USDC>(bridge_root, string::utf8(b"USDC"), string::utf8(b"USDC"), decimals, 1000000000000);
//         register_coin<WETH>(bridge_root, string::utf8(b"WETH"), string::utf8(b"WETH"), decimals, 1000000000000); // also registers WETH

//         let remote_coin_addr = @props_bridge;
//         let remote_coin_addr_bytes = bcs::to_bytes(&remote_coin_addr);
//         set_remote_coin<USDC>(bridge_root, remote_chain_id, remote_coin_addr_bytes, false);
//         set_remote_coin<WETH>(bridge_root, remote_chain_id, sha3_256(remote_bridge_addr_bytes), false); // also configure the weth

//         // mock packet for receiving coin: remote chain -> local chain
//         let nonce = 1;
//         let amount_sd = 100000000000;
//         let payload = build_receive_coin_payload(remote_bridge_addr_bytes, alice_addr_bytes, amount_sd);
//         let emitted_packet = packet::new_packet(remote_chain_id, remote_bridge_addr_bytes, local_chain_id, local_bridge_addr_bytes, nonce, payload);

//         test_helpers::deliver_packet<BridgeUA>(oracle_root, relayer_root, emitted_packet, 20);

//         //instead of using USDC, we use WETH trying to decieve the function
//         // it should fail here with EBRIDGE_INVALID_COIN_TYPE
//         lz_receive<WETH>(remote_chain_id, remote_bridge_addr_bytes, payload);
//     }

//     #[test(aptos = @aptos_framework, core_resources = @core_resources, layerzero_root = @layerzero, msglib_auth_root = @msglib_auth, bridge_root = @props_bridge, oracle_root = @1234, relayer_root = @5678, executor_root = @1357, executor_auth_root = @executor_auth, alice = @0xABCD)]
//     #[expected_failure(abort_code = 0x50000, location = Self)]
//     public entry fun test_receive_unregistered_coin(aptos: &signer, core_resources: &signer, layerzero_root: &signer, msglib_auth_root: &signer, bridge_root: &signer, oracle_root: &signer, relayer_root: &signer, executor_root: &signer, executor_auth_root: &signer, alice: &signer) acquires EventStore, CoinStore, CoinTypeStore, Config, LzCapability {
//         use layerzero::test_helpers;
//         use layerzero_common::packet;

//         setup(aptos, core_resources, layerzero_root, msglib_auth_root, bridge_root, oracle_root, relayer_root, executor_root, executor_auth_root, alice);

//         let alice_addr = address_of(alice);
//         let alice_addr_bytes = bcs::to_bytes(&alice_addr);

//         // prepare the endpoint
//         let local_chain_id: u64 = 20030;
//         let remote_chain_id: u64 = 20030;
//         test_helpers::setup_layerzero_for_test(layerzero_root, msglib_auth_root, oracle_root, relayer_root, executor_root, executor_auth_root, local_chain_id, remote_chain_id);
//         // assumes layerzero is already initialized
//         init_module(bridge_root);

//         // config bridge
//         let local_bridge_addr = @props_bridge;
//         let remote_bridge_addr = @props_bridge;
//         let remote_bridge_addr_bytes = bcs::to_bytes(&remote_bridge_addr);
//         let local_bridge_addr_bytes = bcs::to_bytes(&local_bridge_addr);
//         remote::set(bridge_root, remote_chain_id, remote_bridge_addr_bytes);

//         // config coin, only register USDC
//         let decimals = 8;
//         register_coin<USDC>(bridge_root, string::utf8(b"USDC"), string::utf8(b"USDC"), decimals, 1000000000000);

//         let remote_coin_addr = @props_bridge;
//         let remote_coin_addr_bytes = bcs::to_bytes(&remote_coin_addr);
//         set_remote_coin<USDC>(bridge_root, remote_chain_id, remote_coin_addr_bytes, false);

//         // mock packet for receiving WETH coin: remote chain -> local chain
//         let nonce = 1;
//         let amount_sd = 100000000000;
//         let remote_weth_addr = sha3_256(remote_bridge_addr_bytes);
//         let payload = build_receive_coin_payload(remote_weth_addr, alice_addr_bytes, amount_sd);
//         let emitted_packet = packet::new_packet(remote_chain_id, remote_bridge_addr_bytes, local_chain_id, local_bridge_addr_bytes, nonce, payload);

//         test_helpers::deliver_packet<BridgeUA>(oracle_root, relayer_root, emitted_packet, 20);

//         // it should fail here with EBRIDGE_UNREGISTERED_COIN for WETH
//         lz_receive<WETH>(remote_chain_id, remote_bridge_addr_bytes, payload);
//     }

//     #[test(aptos = @aptos_framework, core_resources = @core_resources, layerzero_root = @layerzero, msglib_auth_root = @msglib_auth, bridge_root = @props_bridge, oracle_root = @1234, relayer_root = @5678, executor_root = @1357, executor_auth_root = @executor_auth, alice = @0xABCD)]
//     #[expected_failure(abort_code = 0x60004, location = Self)]
//     public entry fun test_claminable_coin_not_found(aptos: &signer, core_resources: &signer, layerzero_root: &signer, msglib_auth_root: &signer, bridge_root: &signer, oracle_root: &signer, relayer_root: &signer, executor_root: &signer, executor_auth_root: &signer, alice: &signer) acquires EventStore, CoinStore, CoinTypeStore, Config {
//         use layerzero::test_helpers;

//         setup(aptos, core_resources, layerzero_root, msglib_auth_root, bridge_root, oracle_root, relayer_root, executor_root, executor_auth_root, alice);

//         // prepare the endpoint
//         let local_chain_id: u64 = 20030;
//         let remote_chain_id: u64 = 20030;
//         test_helpers::setup_layerzero_for_test(layerzero_root, msglib_auth_root, oracle_root, relayer_root, executor_root, executor_auth_root, local_chain_id, remote_chain_id);
//         // assumes layerzero is already initialized
//         init_module(bridge_root);

//         // config bridge
//         remote::set(bridge_root, remote_chain_id, bcs::to_bytes(&@props_bridge));

//         // config coin, only register USDC
//         let decimals = 8;
//         register_coin<USDC>(bridge_root, string::utf8(b"USDC"), string::utf8(b"USDC"), decimals, 1000000000000);

//         let remote_coin_addr = @props_bridge;
//         let remote_coin_addr_bytes = bcs::to_bytes(&remote_coin_addr);
//         set_remote_coin<USDC>(bridge_root, remote_chain_id, remote_coin_addr_bytes, false);

//         // it should fail here with EBRIDGE_CLAIMABLE_COIN_NOT_FOUND
//         claim_coin<USDC>(alice);
//     }

//     #[test(aptos = @aptos_framework, core_resources = @core_resources, layerzero_root = @layerzero, msglib_auth_root = @msglib_auth, bridge_root = @props_bridge, oracle_root = @1234, relayer_root = @5678, executor_root = @1357, executor_auth_root = @executor_auth, alice = @0xABCD)]
//     #[expected_failure(abort_code = 0x10006, location = aptos_framework::coin)]
//     public entry fun test_send_with_insufficient_balance(aptos: &signer, core_resources: &signer, layerzero_root: &signer, msglib_auth_root: &signer, bridge_root: &signer, oracle_root: &signer, relayer_root: &signer, executor_root: &signer, executor_auth_root: &signer, alice: &signer) acquires EventStore, CoinStore, CoinTypeStore, Config, LzCapability {
//         use layerzero::test_helpers;

//         setup(aptos, core_resources, layerzero_root, msglib_auth_root, bridge_root, oracle_root, relayer_root, executor_root, executor_auth_root, alice);

//         // prepare the endpoint
//         let local_chain_id: u64 = 20030;
//         let remote_chain_id: u64 = 20030;
//         test_helpers::setup_layerzero_for_test(layerzero_root, msglib_auth_root, oracle_root, relayer_root, executor_root, executor_auth_root, local_chain_id, remote_chain_id);
//         // assumes layerzero is already initialized
//         init_module(bridge_root);

//         // config bridge
//         remote::set(bridge_root, remote_chain_id, bcs::to_bytes(&@props_bridge));

//         // config coin, only register USDC
//         let decimals = 8;
//         register_coin<USDC>(bridge_root, string::utf8(b"USDC"), string::utf8(b"USDC"), decimals, 1000000000000);

//         let remote_coin_addr = @props_bridge;
//         let remote_coin_addr_bytes = bcs::to_bytes(&remote_coin_addr);
//         set_remote_coin<USDC>(bridge_root, remote_chain_id, remote_coin_addr_bytes, false);

//         // alice register USDC coin but with 0 balance
//         coin::register<USDC>(alice);
//         send_coin_from<USDC>(alice, remote_chain_id, bcs::to_bytes(&address_of(alice)), 100000000000, 0, 0, false, vector::empty(), vector::empty());
//     }

//     #[test(aptos = @aptos_framework, core_resources = @core_resources, layerzero_root = @layerzero, msglib_auth_root = @msglib_auth, bridge_root = @props_bridge, oracle_root = @1234, relayer_root = @5678, executor_root = @1357, executor_auth_root = @executor_auth, alice = @0xABCD)]
//     #[expected_failure]
//     public entry fun test_send_with_unregistered_coin(aptos: &signer, core_resources: &signer, layerzero_root: &signer, msglib_auth_root: &signer, bridge_root: &signer, oracle_root: &signer, relayer_root: &signer, executor_root: &signer, executor_auth_root: &signer, alice: &signer) acquires EventStore, CoinStore, CoinTypeStore, Config, LzCapability {
//         use layerzero::test_helpers;

//         setup(aptos, core_resources, layerzero_root, msglib_auth_root, bridge_root, oracle_root, relayer_root, executor_root, executor_auth_root, alice);

//         // prepare the endpoint
//         let local_chain_id: u64 = 20030;
//         let remote_chain_id: u64 = 20030;
//         test_helpers::setup_layerzero_for_test(layerzero_root, msglib_auth_root, oracle_root, relayer_root, executor_root, executor_auth_root, local_chain_id, remote_chain_id);
//         // assumes layerzero is already initialized
//         init_module(bridge_root);

//         // config bridge
//         remote::set(bridge_root, remote_chain_id, bcs::to_bytes(&@props_bridge));

//         // config coin, only register USDC
//         let decimals = 8;
//         register_coin<USDC>(bridge_root, string::utf8(b"USDC"), string::utf8(b"USDC"), decimals, 1000000000000);

//         let remote_coin_addr = @props_bridge;
//         let remote_coin_addr_bytes = bcs::to_bytes(&remote_coin_addr);
//         set_remote_coin<USDC>(bridge_root, remote_chain_id, remote_coin_addr_bytes, false);

//         // fail to send APT coin
//         send_coin_from<AptosCoin>(alice, remote_chain_id, bcs::to_bytes(&address_of(alice)), 100000, 0, 0, false, vector::empty(), vector::empty());
//     }
}