// SPDX-License-Identifier: MIT
pragma solidity ^0.8.3;

import "@openzeppelin/contracts/access/Ownable.sol";
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
    //Deriving agreementId from Counters library
    Counters.Counter public agreementId;

     uint256 public constant  AGREEMENT_TIME = 4 hours;

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
    event SellerClaim(uint256 nftTokenId, address indexed seller);
    event BuyerClaim(uint256 nftTokenId, address indexed buyer);
    event AgreementEnded(
        uint256 nftTokenId,
        address indexed buyer,
        bool saleEnded
    );
    event Received(address sender, uint256 amount, string message);

    //Modelling the agreement
   struct Agreements {
        address nftContractAddress;
        uint nftTokenId;
        address seller;
        bool saleEnded;
        uint agreementEndAt;
        uint price;
        bool onBit;
        //map amount paid in bit to each bit buyer
     mapping( address => uint) bit;
    }
   //map from agreementId => seller => totalPayForSeller
     mapping( uint => mapping(address => uint)) public totalPayForSeller;

    //Map each agreement to its agreementId
    mapping(uint256 => Agreements) public agreements;

    modifier canListNFT(address _nftContractAddress, uint256 _nftTokenId) {
        require(
            IERC721(_nftContractAddress).ownerOf(_nftTokenId) == msg.sender,
            "You can only list only the NFT you own"
        );
        _;
    }
    modifier canBuyNow(uint256 _agreementId) {
        Agreements storage agreement = agreements[_agreementId];
        require(msg.sender != agreement.seller, "NFT owner cannot buy his NFT");
        require(
            msg.value == agreement.price,
            "Value sent must be equal to NFT price"
        );
        require(
            agreement.onBit == false,
            "A buyer has partly paid for this token"
        );
        _;
    }
    
    modifier canBuyInBits(uint256 _agreementId) {
        Agreements storage agreement = agreements[_agreementId];
        require(msg.sender != agreement.seller, "NFT owner cannot buy his NFT");
        require(
            totalPayForSeller[_agreementId][agreement.seller] ==
                agreement.bit[msg.sender],
            "This NFT has already been partly paid by another buyer"
        );
        require(
            block.timestamp < agreement.agreementEndAt,
            "agreement time has elapsed"
        );
        _;
    }
   
    modifier CanClaim(uint256 _agreementId) {
        Agreements storage agreement = agreements[_agreementId];
        require(
            agreement.saleEnded == true,
            "NFT Sale agreement has not ended yet"
        );
        require(
            block.timestamp >= agreement.agreementEndAt,
            "The agreement has not ended yet"
        );
        require(
                agreement.price > agreement.bit[msg.sender],
                "total payment made"
        );
        _;
    }

    modifier agreementEnded(uint256 _agreementId) {
        Agreements storage agreement = agreements[_agreementId];
        require(
            agreement.saleEnded == true &&
                (block.timestamp >= agreement.agreementEndAt),
            "agreement duration has not ended"
        );
        _;
    }


    //ListToken function help list NFT with its token contract address,tokenId and a price.
    //NFT can be bought between now and the next 40 days otherwise, it has to be re-listed
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
        // update each property of the agreement struct
        agreement.nftContractAddress = _nftContractAddress;
        agreement.nftTokenId = _nftTokenId;
        agreement.seller = msg.sender;
        agreement.saleEnded = false;
        agreement.price = _price;
        agreement.onBit = false;
        //The real agreement time is for 40 days but for testing purpose,we use 4 hours
        agreement.agreementEndAt = block.timestamp + AGREEMENT_TIME;
        emit NewNFTListed(_nftContractAddress, _nftTokenId, msg.sender, _price);
        return currentId;
    }

    //buyNow function is called when the buyer wishes to pay all the ether requested by the seller
    function buyNow(
        uint256 _agreementId,
        uint256 _nftTokenId
    ) public payable canBuyNow(_agreementId) returns (bool) {
        Agreements storage agreement = agreements[_agreementId];
        //calculate commission
        uint256 commisionedValue = (agreement.price * 95) / 100;
        uint256 contractValue = (agreement.price * 5) / 100;
        //Prevent re-entrancy attack
        agreement.price = 0;
        //ether  (amount= price minus contract commission) is sent from the contract to the seller
        (bool done, ) = payable(agreement.seller).call{value: commisionedValue}(
            ""
        );
        require(done, "Cannot send ether to the seller");

        //Send contract commission in form of ether to the smart contract owner
        (bool etherSent, ) = payable(Ownable.owner()).call{
            value: contractValue
        }("");
        require(etherSent, "Cannot send ether to the contract owner");

        //Smart contract sends nft to the buyer
        IERC721(agreement.nftContractAddress).safeTransferFrom(
            address(this),
            msg.sender,
            _nftTokenId
        );
        agreement.onBit = false;
         agreement.saleEnded = true;
        emit NftBought(_nftTokenId, agreement.seller, msg.sender, agreement.price);
        return true;
    }
    function handlePayOut(
        uint256 _agreementId,
        uint256 _nftTokenId
    )   public payable {
        Agreements storage agreement = agreements[_agreementId];
        uint256 bal = agreement.bit[msg.sender];
        uint256 commisionedValue = (bal * 95) / 100;
        uint256 contractValue = (bal * 5) / 100;
        //sends seller's balance minus  contractValue to the seller
        (bool isSent, ) = payable(agreement.seller).call{value: commisionedValue}("");
        require(isSent, "Cannot send ether to the seller");
        //sends smart contract owners commission
        (bool hasSent, ) = payable(Ownable.owner()).call{value: contractValue}(
            ""
        );
        require(hasSent, "Cannot send ether to the seller");
        //sends NFT to the buyer
        IERC721(agreement.nftContractAddress).safeTransferFrom(
            address(this),
            msg.sender,
            _nftTokenId
        );
        
        emit AgreementEnded(_nftTokenId, agreement.seller, agreement.saleEnded);
    }
    //BuyInBit function is called by buyers who intend to buy the NFT in installments.
    function buyInBit(
        uint256 _agreementId,
        uint256 _nftTokenId
    )
        public
        payable
        canBuyInBits(_agreementId)
        returns (bool success)
    {
        Agreements storage agreement = agreements[_agreementId];
        (bool isSent, ) = payable(address(this)).call{value: msg.value}("");
        require(isSent, "Cannot send ether to the seller");
        agreement.bit[msg.sender] += msg.value;
        totalPayForSeller[_agreementId][agreement.seller] += msg.value;
    
        if (
            totalPayForSeller[_agreementId][agreement.seller] ==
            agreement.price &&
            agreement.bit[msg.sender] >= agreement.price &&
            block.timestamp >= agreement.agreementEndAt
        ) {
            handlePayOut( _agreementId, _nftTokenId);
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
        uint256 _agreementId,
        uint256 _nftTokenId
    ) external CanClaim(_agreementId) {
        Agreements storage agreement = agreements[_agreementId];
        //calculate seller's compensation
        uint256 bal = totalPayForSeller[_agreementId][msg.sender];
        uint256 compensationFee = (bal * 5) / 100;
        //Smart contract sends compensation ether to the seller
        (bool compensationSent, ) = payable(msg.sender).call{
            value: compensationFee
        }("");
        require(compensationSent, "Cannot send ether to the seller");
        //Smart contract sends token to the seller
        IERC721(agreement.nftContractAddress).safeTransferFrom(
            address(this),
            msg.sender,
            _nftTokenId
        );
        agreement.saleEnded = true;
        
        emit SellerClaim(_nftTokenId, msg.sender);
        emit AgreementEnded(_nftTokenId, msg.sender, agreement.saleEnded);
    }

    //BuyerClaimFund function is used by the buyer to claim his nft when he fails to pay all installment before the end of the agreement period
    function buyerClaimFund(uint256 _agreementId, uint256 _nftTokenId)
        external
        CanClaim(_agreementId)
        returns (bool success)
    {
        Agreements storage agreement = agreements[_agreementId];
        //calculate buyer's due
        uint256 bal = agreement.bit[msg.sender];
        uint256 buyersDue = (bal * 90) / 100;
        uint256 contractFee =(bal *5) / 100;
        //Smart contract sends ether to the buyer
        (bool dueSent, ) = payable(msg.sender).call{value: buyersDue}(
            ""
        );
        require(dueSent, "Cannot send ether to the buyer");
        //Smart contract sends ether to the owner
        (bool feeSent, ) = payable(msg.sender).call{value: contractFee}(
            ""
        );
        require(feeSent, "Cannot send ether to the buyer");
        agreements[_agreementId].saleEnded = true;
        emit BuyerClaim(_nftTokenId, msg.sender);
        emit AgreementEnded(
            _nftTokenId,
            msg.sender,
            agreements[_agreementId].saleEnded
        );
        return (success);
    }
      //A view function that returns  AgreementId
    // function getAgreementId(
    //     address _nftContractAddress,
    //     uint256 _nftTokenId,
    //     uint256 _price )
    //     public
    //     view
    //     returns (uint256)
    // {

    //     return 
    // }

    //A view function that returns  Bit-NFT-MarketPlace Commission
    function getBitMktCommision(uint256 _agreementId)
        public
        view
        returns (uint256)
    {
        return (agreements[_agreementId].price * 5) / 100;
    }

    //A view function that returns the fund receivable by an NFT seller
    function getSellersFundReceivable(uint256 _agreementId)
        public
        view
        returns (uint256)
    {
        return (agreements[_agreementId].price * 95) / 100;
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

