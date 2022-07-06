// SPDX-License-Identifier: MIT
pragma solidity ^0.8.3;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

//Bit-NFT-Marketplace is a marketplace where you as a seller can list your erc721 tokens
//for sale either on cash and carry basis or on installmental basis.
//It is a platform where buyers can buy NFT in dribs and drabs.
//sellers sends their nft to the contract using its address and the tokenId where it is secured.
//At the end of the duration of the sale which is 40 days,the seller gets his ether while the buyer gets his NFT
//if the buyer defaults,he/she forfeits 10% of total ether sent(5% for the marketplace and 5% compensation to the seller)
//And the seller gets back his NFT while the buyer gets back his ether minus 10% of total.
//If it is an instant sale,the marketplace receive 5% of the NFT price otherwise all funds go to seller..

contract BitNFTMarketPlace is Ownable, IERC721Receiver {
    using Counters for Counters.Counter;
    Counters.Counter public agreementId;
     uint public immutable AGREEMENT_TIME ; //40 days but 40 minutes for testing

     //constructor
     constructor(){
        AGREEMENT_TIME =  40 minutes;
    }
    //All events to be emitted
    event NewNFTListed(
        address nftContractAddress,
        uint256 nftTokenId,
        address indexed seller,
        uint256 price
    );

    event NftBought(
        uint256 nftTokenId,
        address indexed seller,
        address indexed buyer,
        uint256 price
    );

    event BitBuy(
        uint256 nftTokenId,
        address indexed seller,
        address buyer,
        uint256 price
        );

    event SellerClaim(
        uint256 nftTokenId, 
        address indexed seller);

    event BuyerClaim(
         uint256 nftTokenId,
         address indexed buyer
         );

    event AgreementEnded(
        uint256 nftTokenId,
        address indexed buyer,
        bool saleEnded
    );

    event Received(
        address sender, 
        uint256 amount, 
        string message
        );

    //Modelling the agreement
   struct Agreements {
        address nftContractAddress;
        uint nftTokenId;
        address seller;
        bool saleEnded;
        uint agreementEndAt;
        uint price;
        bool onBit;
     mapping( address => uint) bit;
    }
   
     mapping( uint => mapping(address => uint)) public totalPayForSeller;

    mapping(uint256 => Agreements) public agreements;

    modifier canListNFT(address _nftContractAddress, uint256 _nftTokenId) {
        require(
            IERC721(_nftContractAddress).ownerOf(_nftTokenId) == msg.sender,
            "You can only list the NFT you own"
        );
        _;
    }
    modifier canBuyNow(uint256 _agreementId) {
        Agreements storage agreement = agreements[_agreementId];
        require(msg.sender != agreement.seller, "NFT owner cannot buy his NFT");
        require(
            msg.value == agreements[_agreementId].price ,
            "Value sent must be equal to NFT price"
        );
        require(
            agreements[_agreementId].onBit == false,
            "A buyer has partly paid for this token"
        );

         require(
            agreement.price == msg.value,
            "You must send a value equal to the NFT price"
        );
        (bool done, ) = payable(agreement.seller).call{value: (msg.value * 95)/100}("");
        require(done, "Cannot send ether to the seller");

         (bool etherSent, ) = payable(Ownable.owner()).call{value: (msg.value * 5)/100}("");
        require(etherSent, "Cannot send ether to the contract owner");
        _;
    }
    
    modifier canBuyInBits(uint256 _agreementId,address) {
        Agreements storage agreement = agreements[_agreementId];
        require(msg.sender != agreements[_agreementId].seller, 
            "NFT owner cannot buy his NFT"
            );
         require( agreement.bit[msg.sender] > 0 || agreement.onBit == false,
             "This NFT has already been partly paid for by another buyer"
         );
        require(block.timestamp < agreements[_agreementId].agreementEndAt,
            "agreement time has elapsed"
        );
        _;
    }
   
    modifier CanClaim(uint256 _agreementId) {
        Agreements storage agreement = agreements[_agreementId];
    
        require(
            block.timestamp >= agreements[_agreementId].agreementEndAt,
            "The agreement has not ended yet"
        );
        require(
                  agreement.bit[msg.sender] <= agreements[_agreementId].price,
                "Token sent already"
        );
        _;
    }

    modifier agreementEnded(uint256 _agreementId) {
        Agreements storage agreement = agreements[_agreementId];
        require(
            agreement.saleEnded == true &&
                (block.timestamp >= agreements[_agreementId].agreementEndAt),
            "agreement duration has not ended"
        );
        _;
    }


    //ListToken function help list NFT with its token contract address,tokenId and a price
    function listToken(
        address _nftContractAddress,
        uint256 _nftTokenId,
        uint256 _price
    )
        public
        payable
        canListNFT(_nftContractAddress, _nftTokenId)
        returns (uint256 _Id)
    {
        IERC721(_nftContractAddress).safeTransferFrom(
            msg.sender,
            address(this),
            _nftTokenId
        );
        
        uint256 currentId = agreementId.current();
        agreementId.increment();
        Agreements storage agreement = agreements[currentId];
        agreement.nftContractAddress = _nftContractAddress;
        agreement.nftTokenId = _nftTokenId;
        agreement.seller = msg.sender;
        agreement.saleEnded = false;
        agreement.price = _price;
        agreement.onBit = false;
        agreement.agreementEndAt = block.timestamp + AGREEMENT_TIME;
        emit NewNFTListed(_nftContractAddress, _nftTokenId, msg.sender, _price);
        return currentId;
    }

    //buyNow function is called when the buyer wishes to pay all the ether requested by the seller
    function buyNow(address _nftContractAddress,
        uint256 _agreementId,
        uint256 _nftTokenId,
        address _seller
    ) public payable canBuyNow(_agreementId) returns (bool) {
        Agreements storage agreement = agreements[_agreementId];
       agreement.price = 0;
          
        IERC721(_nftContractAddress).safeTransferFrom(
            address(this),
            msg.sender,
            _nftTokenId
        );
        
        agreements[_agreementId].onBit = false;
         agreements[_agreementId].saleEnded = true;
        emit NftBought(_nftTokenId, _seller, msg.sender, agreement.price);
        return true;
    }
    function handlePayOut(
        address _nftContractAddress,
        uint256 _agreementId,
        uint256 _nftTokenId,
        address _seller
    )   public payable {
        Agreements storage agreement = agreements[_agreementId];
        (bool isSent, ) = payable(_seller).call{value: (msg.value * 95)/100}("");
        require(isSent, "Cannot send ether to the seller");

        (bool hasSent, ) = payable(Ownable.owner()).call{value: (msg.value * 5)/100}(
            ""
        );
        require(hasSent, "Cannot send ether to the owner");

        IERC721(_nftContractAddress).safeTransferFrom(
            address(this),
            msg.sender,
            _nftTokenId
        );
        agreements[_agreementId].saleEnded = true;
        
        emit AgreementEnded(_nftTokenId, agreement.seller, agreement.saleEnded);
    }
    //BuyInBit function is called by buyers who intend to buy the NFT in installments.
    function buyInBit(
        address _nftContractAddress,
        uint256 _agreementId,
        uint256 _nftTokenId,
        address _seller
    )
        public
        payable
        canBuyInBits(_agreementId,_seller)
        returns (bool success)
    {
        Agreements storage agreement = agreements[_agreementId];
        agreement.bit[msg.sender] += msg.value;
       
        if (
            agreement.bit[msg.sender] == agreements[_agreementId].price 
            
        ) {
            handlePayOut( _nftContractAddress, _agreementId, _nftTokenId,_seller);
            emit AgreementEnded(_nftTokenId, msg.sender, agreement.saleEnded);
        } else
            emit BitBuy(
                _nftTokenId,
                agreement.seller,
                msg.sender,
                agreement.price
            );
        return (success);
    }

    //This function is used by the seller at the expiry of the installment agreement
    function sellerClaimNFT(
        address _nftContractAddress,
        uint256 _agreementId,
        uint256 _nftTokenId
    ) public payable CanClaim(_agreementId) {
        Agreements storage agreement = agreements[_agreementId];
         uint bal = totalPayForSeller[_agreementId][msg.sender];
        uint sellersCompensation  = ((bal * 5 )/100);

         (bool done, ) = payable(agreement.seller).call{value:sellersCompensation}("");
        require(done, "Cannot send ether to the seller");

        IERC721(_nftContractAddress).safeTransferFrom(
            address(this),
            msg.sender,
            _nftTokenId
        );
        agreements[_agreementId].saleEnded = true;
        emit SellerClaim(_nftTokenId, msg.sender);
        emit AgreementEnded(_nftTokenId, msg.sender, agreement.saleEnded);
    }

    //BuyerClaimFund function is used by the buyer to claim his nft when he fails to pay all installment before the end of the agreement period
    function buyerClaimFund(
        uint256 _agreementId,
        uint256 _nftTokenId)
        public
        payable
        CanClaim(_agreementId)
        returns (bool success)
    {
        Agreements storage agreement = agreements[_agreementId];
        uint256 bal = agreement.bit[msg.sender];
        uint256 buyersDue = (bal * 90) / 100;
        uint256 contractFee =(bal *5) / 100;

         (bool sentAlready, ) = payable(msg.sender).call{value: buyersDue}("");
        require(sentAlready, "Cannot send ether to the buyer");

         (bool etherSend, ) = payable(Ownable.owner()).call{value: contractFee}("");
        require(etherSend, "Cannot ether default penalty ether to the contract owner");
        
        agreements[_agreementId].saleEnded = true;
        emit BuyerClaim(_nftTokenId, msg.sender);
        emit AgreementEnded(
            _nftTokenId,
            msg.sender,
            agreements[_agreementId].saleEnded
        );
        return (success);
    }
  
    //A view function that returns  Bit-NFT-MarketPlace Commission
    function getBitMktCommision(uint256 _agreementId)
        public
        view
        returns (uint256)
    {
        Agreements storage agreement = agreements[_agreementId];
        return (agreement.price * 5) / 100;
    }

    //A view function that returns the fund receivable by an NFT seller
    function getSellersFundReceivable(uint256 _agreementId)
        public
        view
        returns (uint256)
    {
        Agreements storage agreement = agreements[_agreementId];
        return (agreement.price * 95) / 100;
    }

    //receive function helps the smart contract to receive ether
    receive() external payable {
        emit Received(msg.sender, msg.value, "Fallback was called");
    }

    // onERC721Received function helps the smart contract to receive NFT
    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) external pure override returns (bytes4) {
        return this.onERC721Received.selector;
    }
}

