struct BlobVector {
    let plaintextLength: UInt64
    let partCount: Int
    let ciphertextLength: UInt64
    let lastPartLength: Int
    let contentHash: String
    let partHashes: [String]
    let objectID: String
    let wrongRoutePartHashes: [String]
    let wrongRouteObjectID: String
}

enum BlobVectors {
    static let key = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
    static let route = "202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f"
    static let wrongRoute = "404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f"
    static let rejectedPlaintextLengths: [UInt64] = [0, 10485761]
    static let rejectedCiphertextLengths: [UInt64] = [0, 16, 524320, 10486081, 10486097]
    static let oneByteCiphertext = "0e641245ad31c9517a64af6559a1189f41"
    static let descriptorPlaintextLength: UInt64 = 524289
    static let descriptorBytes = "475342310100920a32e8b666c99e6061d66420cbf2f3516af424455560215e554c77fd298915000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f00000000000800015584f83643017fcea9b7d65d3d3f890b5219eb1abfcb8896a2d4ef554d4612ec00000640000004b00b7075626c69632e6a706567"
    static let descriptorDigest = "979a79bcc15ae81fb808471371336504f05396d8b5c6a216da14c81db72c94f6"
    static let accepted: [BlobVector] = [
        BlobVector(
            plaintextLength: 1,
            partCount: 1,
            ciphertextLength: 17,
            lastPartLength: 17,
            contentHash: "6e340b9cffb37a989ca544e6bb780a2c78901d3fb33738768511a30617afa01d",
            partHashes: [
                "b933fe28ed03ee4fe8e487e09c24d676c8b377635537eafb4ccb7b9dfa8d1602",
            ],
            objectID: "3106d87271be96bcdca70c4232e68f33b8422c1e23f34fd43e663d1fc424536d",
            wrongRoutePartHashes: [
                "f92d89522dd654207f64abe936ca7b61793bae72ef2cc46f517fbd6acfb75619",
            ],
            wrongRouteObjectID: "a233a6259651e6ddbc44a526c8c59505ac912a7f383d443df06325cdc96e114b"
        ),
        BlobVector(
            plaintextLength: 524287,
            partCount: 1,
            ciphertextLength: 524303,
            lastPartLength: 524303,
            contentHash: "82cfb9d85b72179ba581e23356fbcbfd81ecccb84191fec6b3cb3f133d3ba73a",
            partHashes: [
                "876f61fca1c2166c0d5663384ebe21901d86881b38c4b3e48dda0c76d21d1226",
            ],
            objectID: "998cc0f19841fb0dc8f78995c1fdca41d49d9967bfbf056d504885d88c6aa3b4",
            wrongRoutePartHashes: [
                "a4b93cfd70b015f329d24d54378f493cbc9d1284ba6d2b0966023772baf30e81",
            ],
            wrongRouteObjectID: "1d2e523dac83e5fe68f01f505dbe1f15c9ca1ededade1e57ea16898e174492ef"
        ),
        BlobVector(
            plaintextLength: 524288,
            partCount: 1,
            ciphertextLength: 524304,
            lastPartLength: 524304,
            contentHash: "61d1d9c5745bdaa4fab39240651bc242a5186b15393fd475082fcf6e84f400ab",
            partHashes: [
                "d69538adc41bb6686d8c620a156434dd8533df4cbf42aad0496830b612370bab",
            ],
            objectID: "e7a2e1ac816f9d0d4c7ecafa67e4bb7a7a9f441857c82613f2188b505ff83786",
            wrongRoutePartHashes: [
                "5c1cc2fcccbc7df35b82e36605d0fe57a357d1c53c826b6c21d9d411501cff16",
            ],
            wrongRouteObjectID: "0274956e0561fbbd31cf34cb634d5a8058fd89f4e0f85fdfe68d4fb5cc4702dc"
        ),
        BlobVector(
            plaintextLength: 524289,
            partCount: 2,
            ciphertextLength: 524321,
            lastPartLength: 17,
            contentHash: "5584f83643017fcea9b7d65d3d3f890b5219eb1abfcb8896a2d4ef554d4612ec",
            partHashes: [
                "8e1a08459558afb0990a464d5c0868c85da8d4d86e50808b412e668cf0772b1d",
                "c8eb40b956db28fcbf6b4c809aaa7417fd9d48622a8f830693504d081b1fad9b",
            ],
            objectID: "920a32e8b666c99e6061d66420cbf2f3516af424455560215e554c77fd298915",
            wrongRoutePartHashes: [
                "c23fd5905ef8af36bc96268f635524d81c74f06c846705311d688650cc3a7146",
                "5ef8fc8bfac907ca693e7a0cd916c8d99e608e4325ffaf2e8f04e26e868cc98b",
            ],
            wrongRouteObjectID: "68a3c20c52cec4c4aa9d56edcc0b90ed1fb27d75435f75df7a353e6d9b233999"
        ),
        BlobVector(
            plaintextLength: 10485759,
            partCount: 20,
            ciphertextLength: 10486079,
            lastPartLength: 524303,
            contentHash: "9d136967875f50e9b33491517c487a06f94e30e56b65193fe741d9a52741f7ee",
            partHashes: [
                "3c458f24f6ef0104bb02505edb600da67c14834d17f4a96722d70d483080d96f",
                "54217eef767c41f217756ac042ba3ab46b89fede54c89f6211cd44b6ff70c1c1",
                "a21707e2b659117e113093f3a5f50b7760b882a5c2465c5876ede0750573aa51",
                "c80a80a440eba25225bd8feaa9a68991ef6dc0b9bd5ee9243021d5e992eaeb7a",
                "661687a7f823f95bdaf48f463e7366159452b473109b45c872449f7d02415ce5",
                "b6c65e58e2088905fe0e8aea59511289d45c7d220940328379f6948b409633b7",
                "c41eae549407362f94c9f8ba4c92d48911719bbc0dd4a52188934af3b38c9d4f",
                "a986f2da8d5658346caf9e94d59b2aa6f1f092580732b9ab68f467671cb2b100",
                "4fb71e13aca9ad5fe5880b867d653b088176033e656b1eca83b00f130587c442",
                "029f78d5a139773e1254f1dd9241e08530083687ad91725aba62b97e8d9284d3",
                "35a049ce5082036dee2943898bb3c4cfdffebcd2c0e73173a6c1cdf3b1a32f13",
                "9683a059c44ecee8a294927d698182de7603dd977e065f82dc810fcc16ce7e1e",
                "113152ac05192c46cfc7403a9f4b878cbf9b21526d218664dd3432ba80a57a20",
                "dd4151329e2fb64033702e4fa1ff2237a05cc5a1de4cff532c890d43b84b7068",
                "6f0cdd2df0a706772995be4b44364bea0e3ccbb1aa5a6ad035c131beae2c85e9",
                "d74a38768234c222870b64014238fb9ee1416feb3d7d76b552c0bbd52e43f8ba",
                "0cfc4286d72763be364d437530ded89f74eedf2bd06d1815f63b92157168305e",
                "f1cfdbebdcbafdb8ffdabfedfb21a3bff8cd7ae2f02d0d04ebdaa4586ea77719",
                "6acf892e031dcb5e5f5a496a8a6b4df886924904fdd3234a3224f1fd5099a893",
                "bf56305c4f268dfba3836e1f71e98c914a67e51bf2d02ca0b7f323794bdcf72b",
            ],
            objectID: "d48e2a3362caec05db1a63699fa489b1ae8fbf1a3e5c6bd0d9990c0bd68a5ba0",
            wrongRoutePartHashes: [
                "f38634108c02a1989d6d231c987e3786f8a8a1b59b6a3806ddd820e750442ff5",
                "33a55a5195ec38be7aa8ab9050acd64240242c581254b377e36c9892ce5fb783",
                "87641b877830913ce059bb246c282b67f66159711cb796efaabecb26e79eb553",
                "cc8b7ec5128f09794e7ef0f76071f8f311062ca545dfd5362add05ee6e7c67e7",
                "f3915639bf6a865558bc8e3f2cc48415752a80e796e2f054122a406a2fbbf835",
                "65bd66a6771f477b8c9d2b6fd751613ea38b102b55397f0c6d6b9ce9aba7e14c",
                "905e6548e920680b38d60a8b3647c3ee04041a26825fe1ec26e9e677ec03a518",
                "9d63f9fe4501f8dc302772f624bc75b4529435272e84ccc60d993b2ab2393722",
                "765f53f5b2ce94fb52fbe5a08a4cef69f80f240102fedb00134727deb819e29e",
                "5f8ca769c21ae356b36a223a7f0769a0fc629b3b9092388f0f6b9d2f686f1fed",
                "5ae6c6e0014ba1995bc8813b1769b25260a36848ac8d7eedf19cd2d53d49563d",
                "00706ecc3d5915a4920a8426adfbca4b946ba7da90161aa03a3ffbb7574fc976",
                "9fe27be5031da3ff4c9a81668362951bf22cba7a5d7e72d7ef9d37551cc1c609",
                "314ab0d3f489c2e4ebce8e15639e6c3435305cfcf73b55593830aa70a47814a5",
                "3d2fbc9467c5f957aebc13daf06e0ae1cf46dbd5ac77df9218b836a3d0779044",
                "dd908cdab7acfcf387eeffb24332834ba8c930fea367a9dc521f6b754342cf99",
                "aab4754ad5ea7a108713780a8fad5ec7f6746f9889e163de794c18e35b3d3d47",
                "5e1cc2dfcefdd85c863e09d9b5e102d5bbe7963f232d176140dd815452480b9f",
                "7ac183fd9e28fbc27b3efad072eeaba84d40395d4187a30da0b3fa4769f0a427",
                "87917865e0d28e80c302547cdb8fd0330b129afe032b65d6eed59218b7204f6b",
            ],
            wrongRouteObjectID: "c429782b557975bad1724c06bba3306233e5ee3539936f876c997f5b602cbcbf"
        ),
        BlobVector(
            plaintextLength: 10485760,
            partCount: 20,
            ciphertextLength: 10486080,
            lastPartLength: 524304,
            contentHash: "44f9296993796e201208c6c245b9515d36b62c87d0be4459ff347bfa054cd527",
            partHashes: [
                "a213bfad02c0f372f77b375caccd76f36ee6f0a51d59432d6bc37f40fd504cbe",
                "6738cd88c7d94b72fd47e3a6f980189ccf3a84df138e390490aaca0f0e521e11",
                "1784bd4bc7db49626d4bcbee2b63372a0306802cb4eb40ba696fa242ef398620",
                "97711b1b7ebe7f1fe63823ce6d5204adb44769fe96bec84f43f558e829c437d8",
                "ad505055bc03d6e1701fe43af012bed05cb89c7668de79026f12bb48fca7e206",
                "ae3740a6acd2c18bc6698e8b566c8c0a8859716fc891fe63209fe42602972a3c",
                "53112b35c8ad6acb38b19fdccd14064ae4a70e91050b820b07d2761935bb971d",
                "819c877218ab395f951b8b2017916dc2dd69bfb82171da0c9fcdfcb5f51c69f7",
                "5a994bd991194888b36ecce5ffb206ac08a72339f0fbb96d66b7b057af087d16",
                "7c08058fbca8f43a3536f0cb75bf3a33596e58e91d370f4f5c237aa2c6174244",
                "97ee2e48495174a2479683331a7f1191f997cc3ecff2b671b6d58e8982503cfe",
                "4df86444023d623106505c9d5ca2b3d18dba98405c429c040c5a7f32df960fb5",
                "bc8316026086a1a0592e0bc31ae66ebc3c0cee3419bc64d397c82c8d42d12ff8",
                "04e25029785a4985e352e10f8c41a99f38ccef67bbc7b6c6a130d54639fd7610",
                "0001fe5ee01c3a2ecc43ee71c039928f977f533874e03b5e618be6e374142b3b",
                "0dc9974ac1a44c8b1f32a18de25e8580f28832e374333e0fd911158d2f868f29",
                "ada0e22e2c37bac338d3e460ef00c798a8395da680a7707c4c3db0786d7fb1c7",
                "5886a7fb00734301920774c83987a865ef79efb8630b9b1ae239cba2ea50ee6f",
                "f88b146c8799772eed465e28f80026e841f308858df833c6b7102390484cb814",
                "6c1ca6ff4ec2e2b30cca37825dbf983c54008d13cd53adca76a28502d991ca7b",
            ],
            objectID: "a076e0fcb7a6321095ca40ad6b11d5ed5c0444426a12213481b280cbf905cecf",
            wrongRoutePartHashes: [
                "5ebc2e3f0cdc191ff580b9d37f96c3c94949ce46f660baf68de9f718b3e08b51",
                "906fc136ff38b867b21468e14797e156671bb691b80cefe419e38cf09a42da8a",
                "0d2f356b526ec50eb517193ef834ef1e6c7b4db2d8ae84194a6dc090ce056e14",
                "44b57fc3469ca7df289b7451757823c4da4a39d35eb25ee41e586682ec40eea0",
                "6d805332ca543fc19a8e78c8791e6abc9d9333f0062c2b55e0ed00f8c04c49d5",
                "11c5fdcc737d96465abc2faf3a27f8e90da885b90705bd4c81b4ab176d8fd999",
                "3daf6a314390c48494ea58a6951f24c406f66b00dc08eab577c72e054c8e442b",
                "e90b3480405c7d34452a99c82865eb4a5585085297c1ef3d559b02043f0e7733",
                "c6d49b3e742ca2cc9b8852eeb97129c731de2f9452d253166f43bfeadeb536e6",
                "c62afab598dba018c0f15fe5d08f1210e0d00eb113f1886a9354499f2fc99606",
                "67faa76a691f844f6e093c3754c1fa789d057bef3aaeee611be5a573272afe62",
                "8fe00c3be6ce9735afd9050de133ae986b0f60a9e5ca65f6b9410b5c39578c69",
                "c1f3a5cbe6f295c9ae02960c944d7e9a8f496231435cf3d99282df5e956d61d6",
                "ba88a1ade29277af8cd0bf6f582f03a3baa2d9085436dbdabd3ef9961af7dbe6",
                "1ac2869036eb225371fe26ecfb3bc5472124ce3790e3de1264a37c7a7a132a37",
                "cfefa78430647c1cd0d5836628949dd59140bfca9cd4934dd31f790c65d14939",
                "1889686da781c72faeeea19bd7cacb505e5ad3c43453fec06d93ec8038ce8c8b",
                "6030da4abd7d4b4c7d441d00a1f38319b338941e2f3cc5e6296c389110236ef1",
                "70c97f02aa546c5f042e0bcd42c30fe2a077f702ded52bbe43b7d3dfc777a15a",
                "7433e8ae21a2c387bbff0579cd8d204e5c1aac7ffef71f887861ec1c7eca99ec",
            ],
            wrongRouteObjectID: "41f0e05e7c8671b959582f690c245146259322b7cf1f15d337b9af452011109f"
        ),
    ]
}
