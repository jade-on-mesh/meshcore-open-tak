// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Slovenian (`sl`).
class AppLocalizationsSl extends AppLocalizations {
  AppLocalizationsSl([String locale = 'sl']) : super(locale);

  @override
  String get appTitle => 'MeshCore Open TAK';

  @override
  String get nav_contacts => 'Stiki';

  @override
  String get nav_channels => 'Kanali';

  @override
  String get nav_map => 'Karta';

  @override
  String get common_cancel => 'Prekliči';

  @override
  String get common_ok => 'V redu';

  @override
  String get common_connect => 'Poveži se';

  @override
  String get common_unknownDevice => 'Nepoznano naprave';

  @override
  String get common_save => 'Shrani';

  @override
  String get common_delete => 'Izbrisati';

  @override
  String get common_deleteAll => 'Izbriši vse';

  @override
  String get common_close => 'Zapri';

  @override
  String get common_done => 'Done';

  @override
  String get common_edit => 'Uredi';

  @override
  String get common_add => 'Dodaj';

  @override
  String get common_settings => 'Nastavitve';

  @override
  String get common_disconnect => 'Odklopiti';

  @override
  String get common_connected => 'Povezano';

  @override
  String get common_disconnected => 'Odprto';

  @override
  String get common_create => 'Ustvari';

  @override
  String get common_continue => 'Poudarki';

  @override
  String get common_share => 'Deliti';

  @override
  String get common_copy => 'Kopiraj';

  @override
  String get common_retry => 'Ponoviti';

  @override
  String get common_hide => 'Skrita';

  @override
  String get common_remove => 'Izbrisati';

  @override
  String get common_enable => 'Omogoči';

  @override
  String get common_disable => 'Izklopiti';

  @override
  String get common_undo => 'Preobrn';

  @override
  String get messageStatus_sent => 'Pošljeno';

  @override
  String get messageStatus_delivered => 'Dostavljeno';

  @override
  String get messageStatus_pending => 'Pošiljanje';

  @override
  String get messageStatus_failed =>
      'Uspešno ni bilo mogo, da se sporočilo pošlje';

  @override
  String get messageStatus_repeated => 'Slišal sem večkrat';

  @override
  String get messageStatus_failedChannel =>
      'Vaše radio ni moglo poslati tega sporočila.';

  @override
  String messageStatus_resending(int resends, int maxResends) {
    return 'Še ni slišano skozi dovolj ponoviteljev. Poslano $resends od $maxResends-krat.';
  }

  @override
  String messageStatus_hopsNotReached(int hops, int required) {
    return 'Poslano, a nazaj slišano le skozi $hops od $required ponoviteljev. Morda je odšlo še dlje, kot vaše radio sliši.';
  }

  @override
  String get messageStatus_sentChannel =>
      'Poslano. Kanali ne potrjujejo dostave, zato to pomeni le, da je vaše radio poslalo sporočilo.';

  @override
  String get messageStatus_sentDirect => 'Poslano. Čaka se na potrditev stika.';

  @override
  String messageStatus_heardRepeatedCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count-krat',
      few: '$count-krat',
      two: '2-krat',
      one: '1-krat',
    );
    return 'Slišano večkrat $_temp0. Bližnji ponovitelji so sporočilo posredovali naprej.';
  }

  @override
  String get urlImage_enable => 'Omogoči slike iz URL';

  @override
  String get urlImage_possible =>
      'Mogoča slika iz URL; omogočite jo v Nastavitvah.';

  @override
  String get common_reboot => 'Ponoviti';

  @override
  String get common_loading => 'Naložanje...';

  @override
  String get common_notAvailable => '—';

  @override
  String common_voltageValue(String volts) {
    return '$volts V';
  }

  @override
  String common_percentValue(int percent) {
    return '$percent %';
  }

  @override
  String get common_autoRefresh => 'Samodejno osveževanje';

  @override
  String get common_interval => 'Časovni interval';

  @override
  String get scanner_title => 'MeshCore Open TAK';

  @override
  String get connectionChoiceUsbLabel => 'USB';

  @override
  String get connectionChoiceBluetoothLabel => 'Bluetooth';

  @override
  String get connectionChoiceTcpLabel => 'TCP';

  @override
  String get tcpScreenTitle => 'Komunicirajte preko protokola TCP';

  @override
  String get tcpHostLabel => 'IP naslov';

  @override
  String get tcpHostHint => '192.168.40.10';

  @override
  String get tcpPortLabel => 'Vrata';

  @override
  String get tcpPortHint => '5000';

  @override
  String get tcpStatus_notConnected => 'Vnesite končni naslov in se povežite';

  @override
  String tcpStatus_connectingTo(String endpoint) {
    return 'Povezava z $endpoint...';
  }

  @override
  String get tcpErrorHostRequired => 'Potrebna je IP-naslov.';

  @override
  String get tcpErrorPortInvalid => 'Port mora biti med 1 in 65535.';

  @override
  String get tcpErrorUnsupported =>
      'Transport preko protokola TCP ni podprt na tej platformi.';

  @override
  String get tcpErrorTimedOut => 'Povezava TCP je presegla časovno obdobje.';

  @override
  String tcpConnectionFailed(String error) {
    return 'Napaka pri povezavi TCP: $error';
  }

  @override
  String get usbScreenTitle => 'Povežite preko USB';

  @override
  String get usbScreenSubtitle =>
      'Izberite zaznano serijsko napravo in se neposredno povežite z vašo MeshCore napravo.';

  @override
  String get usbScreenStatus => 'Izberite USB naprave';

  @override
  String get usbScreenNote =>
      'USB serijska povezava je aktivna na podprtih napravah Android in na desktop platformah.';

  @override
  String get usbScreenEmptyState =>
      'Niti en USB naprave niso najdeni. Povežite eno in posodobite.';

  @override
  String get usbErrorPermissionDenied =>
      'Dovoljenje za dostop preko USB-ja je bilo zavrnjeno.';

  @override
  String get usbErrorDeviceMissing => 'Izbrani USB napravej je več ne.';

  @override
  String get usbErrorInvalidPort => 'Izberite veljavno USB naprave.';

  @override
  String get usbErrorBusy => 'Že je v teku zahteva za povezavo preko USB.';

  @override
  String get usbErrorNotConnected => 'Ni priklopljenih USB naprave.';

  @override
  String get usbErrorOpenFailed =>
      'Uspešno ni bilo mogo, da se odpre izbran naprave USB.';

  @override
  String get usbErrorConnectFailed =>
      'Niso bilo mogoče uskladiti povezave z izbranim USB napom.';

  @override
  String get usbErrorUnsupported =>
      'USB serijska komunikacija ni podprta na tej platformi.';

  @override
  String get usbErrorAlreadyActive => 'USB povezava je že aktivirana.';

  @override
  String get usbErrorNoDeviceSelected => 'Ni bilo izbranega USB naprave.';

  @override
  String get usbErrorPortClosed => 'USB povezava ni aktivirana.';

  @override
  String get usbErrorConnectTimedOut =>
      'Vzpostavitve ni bilo mogo. Prosimo, da se prepričate, da ima naprave trenutno nameštan firmware USB Companion.';

  @override
  String get usbFallbackDeviceName =>
      'Naprave za serijsko komunikacijo preko spleta';

  @override
  String get usbStatus_notConnected => 'Izberite USB naprave.';

  @override
  String get usbStatus_connecting => 'Povezava z USB napravo...';

  @override
  String get usbStatus_searching => 'Iskanje USB naprav...';

  @override
  String usbConnectionFailed(String error) {
    return 'Napaka pri povezavi preko USB: $error';
  }

  @override
  String get scanner_scanning => 'Skeniram za naprave...';

  @override
  String get scanner_connecting => 'Povezujem se...';

  @override
  String get scanner_disconnecting => 'Odklapljam se...';

  @override
  String get scanner_notConnected => 'Nezavezan';

  @override
  String scanner_connectedTo(String deviceName) {
    return 'Povezan s $deviceName';
  }

  @override
  String get scanner_searchingDevices => 'Iskanje naprav MeshCore...';

  @override
  String get scanner_tapToScan =>
      'Nagneš na skeniranje za najdene naprave MeshCore.';

  @override
  String scanner_connectionFailed(String error) {
    return 'Pošlo je z povezavo: $error';
  }

  @override
  String get scanner_stop => 'Prekliči';

  @override
  String get scanner_scan => 'Skeniraj';

  @override
  String get scanner_bluetoothOff => 'Bluetooth je izklopljen';

  @override
  String get scanner_bluetoothOffMessage =>
      'Prosimo, vklopite Bluetooth, da lahko poiščete naprave.';

  @override
  String get scanner_chromeRequired => 'Zahtevan brskalnik Chrome';

  @override
  String get scanner_chromeRequiredMessage =>
      'Ta spletna aplikacija za podporo Bluetooth zahteva Google Chrome ali brskalnik na osnovi Chromiuma.';

  @override
  String get scanner_enableBluetooth => 'Omogočite Bluetooth';

  @override
  String get scanner_bluetoothWebUnsupported =>
      'Funkcija Bluetooth v brskalniku ni na voljo. Povežite se preko USB-ja namesto tega.';

  @override
  String get device_quickSwitch => 'Hitro preklop';

  @override
  String get device_meshcore => 'MeshCore';

  @override
  String get settings_title => 'Nastavitve';

  @override
  String get settings_deviceInfo => 'Informacije o napravei';

  @override
  String get settings_appSettings => 'Nastavitve aplikacije';

  @override
  String get settings_appSettingsSubtitle =>
      'Obveščanja, sporoščanje in zemljevidi.';

  @override
  String get settings_nodeSettings => 'Nastavitev časa';

  @override
  String get settings_nodeName => 'Ime node-a';

  @override
  String get settings_nodeNameNotSet => 'Ni nastavljeno';

  @override
  String get settings_nodeNameHint => 'Vnesite ime node-a';

  @override
  String get settings_nodeNameUpdated => 'Ime posodobljeno';

  @override
  String get settings_radioSettings => 'Nastavitve radija';

  @override
  String get settings_radioSettingsSubtitle =>
      'Frekvenca, moč, razširitveni faktor';

  @override
  String get settings_radioSettingsUpdated => 'Radio nastavitve posodobljene';

  @override
  String get settings_radioSettingsNotApplied =>
      'Radio teh nastavitev ni uveljavil';

  @override
  String get settings_regionSettings => 'Regioni';

  @override
  String get settings_regionSettingsSubtitle => 'Upravljanje opisanih regionov';

  @override
  String get settings_regionEmptyExplanation =>
      'Regije omejujejo sporočila flood na ponovitelje na določenem območju. Pridobite jih iz bližnjih ponoviteljev ali dodajte regijo po imenu.';

  @override
  String get settings_regionFetchFromRepeaters => 'Pridobi iz ponoviteljev';

  @override
  String get settings_regionDefault => 'Privzeta regija';

  @override
  String get settings_regionDefaultSubtitle =>
      'Uporabljajo jo kanali brez lastne regije';

  @override
  String get settings_regionDefaultNone => 'Brez';

  @override
  String settings_regionUseRadioDefault(String region) {
    return 'Privzeto za radio ($region)';
  }

  @override
  String get settings_regionNoRegion => 'Brez regije (neomejeno)';

  @override
  String get settings_regionRadioDefault => 'Privzeta regija radia';

  @override
  String get settings_regionRadioDefaultSubtitle =>
      'Shranjeno v radiu. Uporabljajo jo flood sporočila, poslana brez regije, iz te aplikacije in iz vsake druge aplikacije, povezane z radiem.';

  @override
  String get settings_regionRadioDefaultUpdated =>
      'Privzeta regija radia je posodobljena';

  @override
  String get settings_regionRadioDefaultFailed =>
      'Privzete regije radia ni bilo mogoče posodobiti';

  @override
  String get settings_regionManagement_screenTitle => 'Regijonsko upravljanje';

  @override
  String get settings_regionNameHint => 'Naslov občine';

  @override
  String get settings_regionAddRegion => 'Dodaj region';

  @override
  String get settings_regionFetchRegions =>
      'Pobražujte izvajne področja iz ponavljalnikov';

  @override
  String get settings_regionFetchRegionsFail => 'Nižnih občin ni izkrali';

  @override
  String get settings_regionFetchRegionsAlreadyExists =>
      'Taj oblasi je več pomanjkan.';

  @override
  String get settings_regionName => 'Naziv Regiona';

  @override
  String get settings_regionDeleted => 'Oblikačena regija';

  @override
  String get settings_deleteRegion => 'Prihoda Region';

  @override
  String settings_deleteRegionConfirm(String region) {
    return 'Ostani $region iz listy regionov?';
  }

  @override
  String get settings_location => 'Lokacija';

  @override
  String get settings_locationSubtitle => 'GPS koordinate';

  @override
  String get settings_locationUpdated => 'Lokacija posodobljena';

  @override
  String get settings_locationBothRequired => 'Vnesite širino in dolžino.';

  @override
  String get settings_locationInvalid =>
      'Neveljavna zemeljska širina ali dolžina.';

  @override
  String get settings_locationGPSEnable => 'Omogoči GPS';

  @override
  String get settings_locationGPSEnableSubtitle =>
      'Omogoči samodejno posodabljanje lokacije z GPS-jem.';

  @override
  String get settings_locationIntervalSec => 'Interval za GPS (Sekunde)';

  @override
  String get settings_locationIntervalInvalid =>
      'Intervallo mora biti vsaj 60 sekund in manj kot 86400 sekund.';

  @override
  String get settings_latitude => 'Širina';

  @override
  String get settings_longitude => 'Dolžina';

  @override
  String get settings_contactSettings => 'Nastavitve stika';

  @override
  String get settings_contactSettingsSubtitle =>
      'Nastavitve za dodajanje stikov.';

  @override
  String get settings_privacyMode => 'Zasebnost';

  @override
  String get settings_privacyModeSubtitle => 'Skrita imena/lokacije v oglasih';

  @override
  String get settings_privacyModeToggle =>
      'Omogoči način zasebnosti, da skrijemo tvoje ime in lokacijo v oglasih.';

  @override
  String get settings_privacyModeEnabled => 'Privatni način je omogočen.';

  @override
  String get settings_privacyModeDisabled => 'Privatni način je onemogočen.';

  @override
  String get settings_privacy => 'Nastavitve zasebnosti';

  @override
  String get settings_privacySubtitle =>
      'Kontrolirajte, katere informacije so deljene.';

  @override
  String get settings_privacySettingsDescription =>
      'Izberite, katere informacije vaš naprava deli z drugimi.';

  @override
  String get settings_denyAll => 'Zavrniti vse';

  @override
  String get settings_allowByContact => 'Dovoli po kontaktnih zastavah';

  @override
  String get settings_allowAll => 'Dovoli vse';

  @override
  String get settings_telemetryBaseMode => 'Osnovni način telemetrije';

  @override
  String get settings_telemetryLocationMode => 'Način delovanja telemetrije';

  @override
  String get settings_telemetryEnvironmentMode =>
      'Način delovanja okolja telemetrije';

  @override
  String get settings_telemetryPerContactHint =>
      'Da stiku dovolite, odprite njegov klepet in v meniju izberite Nastavitve stika.';

  @override
  String get settings_advertLocation => 'Lokacija oglasa';

  @override
  String get settings_advertLocationSubtitle => 'Vključi lokacijo v oglas.';

  @override
  String get settings_autoZeroHopAdvertOnGpsUpdate =>
      'Samodejni zero-hop oglas ob posodobitvi GPS';

  @override
  String get settings_autoZeroHopAdvertOnGpsUpdateSubtitle =>
      'Ko se GPS lokacija spremeni, pošlji zero-hop oglas (zahteva lokacijo v oglasu).';

  @override
  String get settings_multiAck => 'Več potrdil';

  @override
  String get settings_multiAckSubtitle =>
      'Pošiljajte dodatna potrdila ACK za boljšo dostavo; porabi več časa v etru';

  @override
  String get settings_telemetryModeUpdated => 'Način telemetrije posodobljen';

  @override
  String get settings_actions => 'Akcije';

  @override
  String get settings_deleteAllPaths => 'Delete All Paths';

  @override
  String get settings_deleteAllPathsSubtitle =>
      'Clear all path data from contacts.';

  @override
  String get settings_sendAdvertisement => 'Pošlji Oglas';

  @override
  String get settings_sendAdvertisementSubtitle =>
      'Trenutna prisotnost v oddajah';

  @override
  String get settings_advertisementSent => 'Oglas poslan';

  @override
  String get settings_syncTime => 'Nastavi uro';

  @override
  String get settings_syncTimeSubtitle => 'Nastavi uro naprave na čas telefona';

  @override
  String get settings_timeSynchronized => 'Ura sinhronizirana';

  @override
  String get settings_refreshContacts => 'Ponovno obišči kontakte';

  @override
  String get settings_refreshContactsSubtitle =>
      'Ponovno naloži seznam stikov v napravi';

  @override
  String get settings_rebootDevice => 'Ponovni zagon naprave';

  @override
  String get settings_rebootDeviceSubtitle => 'Ponovno zaženi MeshCore napravo';

  @override
  String get settings_rebootDeviceConfirm =>
      'Ste prepričani, da želite ponovno zagnati napravo? Povezava bo prekinjena.';

  @override
  String get settings_debug => 'Odpravljanje napak';

  @override
  String get settings_companionDebugLog => 'Log zapis za odpravljanje napak';

  @override
  String get settings_companionDebugLogSubtitle =>
      'Navodila, odgovori in surova podatka za BLE/TCP/USB.';

  @override
  String get settings_appDebugLog => 'Logi aplikacije';

  @override
  String get settings_appDebugLogSubtitle => 'Debug sporočila aplikacije';

  @override
  String get settings_about => 'Oglejte si';

  @override
  String settings_aboutVersion(String version) {
    return 'MeshCore, različ $version';
  }

  @override
  String get settings_aboutLegalese => 'Odprtokodni projekt MeshCore 2024';

  @override
  String get settings_aboutDescription =>
      'Odprtokodni Flutter klient za naprave za LoRa omrežje MeshCore.';

  @override
  String get settings_aboutOpenMeteoAttribution =>
      'Podatki o višini LOS: Open-Meteo (CC BY 4.0)';

  @override
  String get settings_infoName => 'Ime';

  @override
  String get settings_infoId => 'ID';

  @override
  String get settings_infoStatus => 'Stanje';

  @override
  String get settings_infoBattery => 'Baterija';

  @override
  String get settings_infoPublicKey => 'Javni ključ';

  @override
  String get settings_publicKeyCopied => 'Javni ključ kopiran';

  @override
  String get settings_infoContactsCount => 'Število stikov';

  @override
  String get settings_infoChannelCount => 'Število kanalov';

  @override
  String get settings_infoHardware => 'Hardver';

  @override
  String get settings_infoFirmware => 'Pravilnik';

  @override
  String get settings_presets => 'Prednastavitve';

  @override
  String get settings_presetCustom => 'Po meri';

  @override
  String get settings_radioMatchWarning =>
      'Vsa vozlišča, s katerimi komunicirate, morajo uporabljati enako frekvenco, pasovno širino in SF. Hitrost kodiranja (CR) se lahko razlikuje.';

  @override
  String get settings_frequency => 'Frekvenca (MHz)';

  @override
  String get settings_frequencyHelper => '300,00 - 2500,00';

  @override
  String get settings_frequencyInvalid => 'Neveljavna frekvenca (300-2500 MHz)';

  @override
  String get settings_bandwidth => 'Pasovna širina';

  @override
  String get settings_spreadingFactor => 'Razširitveni faktor';

  @override
  String get settings_codingRate => 'Programska hitrost';

  @override
  String get settings_txPower => 'TX Moč (dBm)';

  @override
  String settings_txPowerRangeHelper(int min, int max) {
    return 'Od $min do $max dBm';
  }

  @override
  String get settings_txPowerInvalid => 'Neveljavna TX moč (0-22 dBm)';

  @override
  String get settings_clientRepeat => 'Neovadno ponavljanje';

  @override
  String settings_clientRepeatFrequencyNote(String freq) {
    return 'Frekvenca nastavljena na $freq MHz za ponavljanje brez omrežja';
  }

  @override
  String get settings_clientRepeatSubtitle =>
      'Omogočite temu naprave, da ponavlja paketne sporočila za druge.';

  @override
  String get settings_clientRepeatFreqWarning =>
      'Za ponovni prenos na brezžični način so potrebne frekvence 433, 869 ali 918 MHz.';

  @override
  String settings_error(String message) {
    return 'Napaka: $message';
  }

  @override
  String get appSettings_title => 'Nastavitve aplikacije';

  @override
  String get appSettings_appearance => 'Prikaži';

  @override
  String get appSettings_theme => 'Tema';

  @override
  String get appSettings_themeSystem => 'Sistemska tema';

  @override
  String get appSettings_themeLight => 'Svetlo';

  @override
  String get appSettings_themeDark => 'Temno';

  @override
  String get appSettings_language => 'Jezik';

  @override
  String get appSettings_languageSystem => 'Sistemska privzeta vrednost';

  @override
  String get appSettings_languageEn => 'Angleščina';

  @override
  String get appSettings_languageFr => 'Francija';

  @override
  String get appSettings_languageEs => 'Španščina';

  @override
  String get appSettings_languageDe => 'Nemščina';

  @override
  String get appSettings_languagePl => 'Poljski';

  @override
  String get appSettings_languageSl => 'Slovenščina';

  @override
  String get appSettings_languagePt => 'Portugalski';

  @override
  String get appSettings_languageIt => 'Italijanščina';

  @override
  String get appSettings_languageZh => '中文';

  @override
  String get appSettings_languageSv => 'Švedska';

  @override
  String get appSettings_languageNl => 'Nizozemsko';

  @override
  String get appSettings_languageSk => 'Slovenščina';

  @override
  String get appSettings_languageBg => 'Български';

  @override
  String get appSettings_languageRu => 'Ruščina';

  @override
  String get appSettings_languageUk => 'Ukrajinsko';

  @override
  String get repeater_pathHashModeOption0 => '0 - 1 bajt';

  @override
  String get repeater_pathHashModeOption1 => '1 - 2 bite';

  @override
  String get repeater_pathHashModeOption2 => '2 - 3 bite';

  @override
  String get repeater_pathHashModeOption3 => '3 - 4 bite';

  @override
  String get settings_pathHashModeHelper =>
      'Velikost ID vozlišča, zapisanega v poti pošiljanih paketov flood: 1 bajt (256 ID, do 64 skokov), 2 bajta (65 tisoč, do 32 skokov), 3 bajti (16 milijonov, do 21 skokov). Večja ID zmanjšajo trčenja, vendar ponovitelji s programsko opremo, starejšo od v1.14, zavrnejo pakete z 2- ali 3-bajtnimi ID.';

  @override
  String settings_requiresFirmware(String version) {
    return 'Zahteva vdelano programsko opremo $version ali novejšo';
  }

  @override
  String get appSettings_channelMinHops =>
      'Ponovno pošiljaj sporočila kanala, dokler ne pridejo dovolj daleč';

  @override
  String get appSettings_channelMinHopsSubtitle =>
      'Če se vaše sporočilo ne vrne skozi dovolj ponoviteljev, ga pošlite ponovno. Porabi več časa v etru.';

  @override
  String appSettings_channelMinHopsCount(int count) {
    return 'Zahtevani skoki: $count';
  }

  @override
  String appSettings_channelMinHopsRetries(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count-krat',
      few: '$count-krat',
      one: '1-krat',
    );
    return 'Pošlite največ $_temp0';
  }

  @override
  String get appSettings_channelMinHopsCountRepeaters =>
      'Štej tudi različne ponovitelje v bližini';

  @override
  String appSettings_channelMinHopsCountRepeatersSubtitle(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count različnih ponoviteljev v bližini',
      few: '$count različni ponovitelji v bližini',
      two: '$count različna ponovitelja v bližini',
      one: '1 ponovitelj v bližini',
    );
    return 'Sporočilo štej za poslano, ko ga ponovi $_temp0, tudi če ne slišite, da potuje naprej.';
  }

  @override
  String get appSettings_enableMessageTracing => 'Omogoči sledenje sporočilom';

  @override
  String get appSettings_enableMessageTracingSubtitle =>
      'Prikaži podrobne metapodatke o usmerjanju in časovnem usklajevanju sporočil';

  @override
  String get appSettings_regionOnHopsLine => 'Regija ob številu skokov';

  @override
  String get appSettings_regionOnHopsLineSubtitle =>
      'Regijo sporočila kanala prikaži v isti vrstici kot število skokov, ne pod njim.';

  @override
  String get appSettings_notifications => 'Obvestila';

  @override
  String get appSettings_enableNotifications => 'Omogoči obvestila';

  @override
  String get appSettings_enableNotificationsSubtitle =>
      'Prejmite obvestila o sporočilih in oglasih';

  @override
  String get appSettings_notificationPermissionDenied =>
      'Odobritev obvestila zavrnjena';

  @override
  String get appSettings_notificationsEnabled => 'Obvestila omogočena';

  @override
  String get appSettings_notificationsDisabled => 'Obvestila so izklopljena';

  @override
  String get appSettings_messageNotifications => 'Obvestila';

  @override
  String get appSettings_messageNotificationsSubtitle =>
      'Pokaži obvestilo ob prejemu novih sporočil.';

  @override
  String get appSettings_batteryOptimization => 'Dejavnost v ozadju';

  @override
  String get appSettings_batteryOptimizationSubtitle =>
      'V nastavitvah baterije nastavite MeshCore Open na „Ne optimiziraj“, da bodo sporočila še naprej prihajala v ozadju';

  @override
  String get appSettings_channelMessageNotifications =>
      'Obvestila o sporočilih kanala';

  @override
  String get appSettings_channelMessageNotificationsSubtitle =>
      'Pokaži obvestilo ob prejemanju sporočil kanala';

  @override
  String get appSettings_advertisementNotifications => 'Opozorila o oglasih';

  @override
  String get appSettings_advertisementNotificationsSubtitle =>
      'Pokaži obvestilo, ko so najdene nove naprave.';

  @override
  String get appSettings_messaging => 'Komuniciranje';

  @override
  String get appSettings_clearPathOnMaxRetry =>
      'Ponovite pot do cilja na največjem štetju';

  @override
  String get appSettings_clearPathOnMaxRetrySubtitle =>
      'Ponovi pot zimske obveščevalne poti po 5 neuspešnih poskusih pošiljanja';

  @override
  String get appSettings_pathsWillBeCleared =>
      'Počisti pot po 5 neuspešnih poskusih.';

  @override
  String get appSettings_pathsWillNotBeCleared =>
      'Poti ne bodo samodejno čiščene.';

  @override
  String get appSettings_autoRouteRotation =>
      'Avtomatsko rotacija prenosne poti';

  @override
  String get appSettings_autoRouteRotationSubtitle =>
      'Menjaj med boljšo potjo in flood načinom';

  @override
  String get appSettings_autoRouteRotationEnabled =>
      'Samodejno krmilno rotiranje omogočeno';

  @override
  String get appSettings_autoRouteRotationDisabled =>
      'Samodejno krmilno rotiranje je onemogočeno';

  @override
  String get appSettings_maxRouteWeight => 'Največja dovoljena teža poti';

  @override
  String get appSettings_maxRouteWeightSubtitle =>
      'Največja teža, ki jo lahko pot doseže s uspešnimi dostavnami.';

  @override
  String get appSettings_initialRouteWeight => 'Izvirna teža poti';

  @override
  String get appSettings_initialRouteWeightSubtitle =>
      'Izguba teže za nove, odkriti poti';

  @override
  String get appSettings_routeWeightSuccessIncrement =>
      'Učinkovitost: povečanje';

  @override
  String get appSettings_routeWeightSuccessIncrementSubtitle =>
      'Težava, dodana poti po uspešni dostavi';

  @override
  String get appSettings_routeWeightFailureDecrement =>
      'Zmanjšanje teže, ki je povezana s pomanjkanjem';

  @override
  String get appSettings_routeWeightFailureDecrementSubtitle =>
      'Težo, ki ni bila uspešno dostavljena, odstranili s poti.';

  @override
  String get appSettings_maxMessageRetries =>
      'Najve število poskusov pošiljanja sporočil';

  @override
  String get appSettings_maxMessageRetriesSubtitle =>
      'Število poskusov ponovnega poslanja, preden se sporočilo označuje kot neuspešno';

  @override
  String get appSettings_battery => 'Baterija';

  @override
  String get appSettings_batteryChemistry => 'Kemija baterije';

  @override
  String appSettings_batteryChemistryPerDevice(String deviceName) {
    return 'Nastavitev za napravo ($deviceName)';
  }

  @override
  String get appSettings_batteryChemistryConnectFirst =>
      'Za izbiro se poveži z napravo';

  @override
  String get appSettings_batteryNmc => '18650 NMC (3,0-4,2V)';

  @override
  String get appSettings_batteryLifepo4 => 'LiFePO4 (2,6–3,65 V)';

  @override
  String get appSettings_batteryLipo => 'LiPo (3,0-4,2V)';

  @override
  String get appSettings_batteryLipoHv => 'LiPo HV (3,0–4,35 V)';

  @override
  String get appSettings_mapDisplay => 'Prikaz zemljevida';

  @override
  String get appSettings_showRepeaters => 'Prikaži repetitorje';

  @override
  String get appSettings_showRepeatersSubtitle => 'Prikaži repetitorje na mapi';

  @override
  String get appSettings_showChatNodes => 'Prikaži naprave za klepet';

  @override
  String get appSettings_showChatNodesSubtitle =>
      'Prikaži naprave na zemljevidu';

  @override
  String get appSettings_showOtherNodes => 'Pokaži druge naprave';

  @override
  String get appSettings_showOtherNodesSubtitle =>
      'Pokaži druge vrste naprav na zemljevidu.';

  @override
  String get appSettings_timeFilter => 'Filter po času';

  @override
  String get appSettings_timeFilterShowAll => 'Pokaži vse naprave';

  @override
  String appSettings_timeFilterShowLast(int hours) {
    return 'Pokaži naprave v zadnjih $hours urah';
  }

  @override
  String get appSettings_mapTimeFilter => 'Filter časa na zemljevidu';

  @override
  String get appSettings_showNodesDiscoveredWithin =>
      'Pokaži naprave odkrite v:';

  @override
  String get appSettings_allTime => 'Brez omejitev';

  @override
  String get appSettings_lastHour => 'V zadnji uri';

  @override
  String get appSettings_last6Hours => 'Zadnjih 6 ur';

  @override
  String get appSettings_last24Hours => 'Zadnjih 24 ur';

  @override
  String get appSettings_lastWeek => 'Prejšnji teden';

  @override
  String get appSettings_rasterTileSource => 'Vir rastrskih ploščic';

  @override
  String get appSettings_stadiaEndpoint => 'Končna točka Stadia';

  @override
  String get appSettings_stadiaApiKey => 'Ključ API Stadia';

  @override
  String get appSettings_stadiaApiKeyRequired =>
      'Obvezno za uporabo Stadia Maps';

  @override
  String appSettings_stadiaApiKeyConfigured(String maskedKey) {
    return 'Nastavljeno: $maskedKey';
  }

  @override
  String get appSettings_stadiaApiKeyDialogDescription =>
      'Vnesite svoj ključ API za Stadia Maps. Aplikacija ga uporablja za zahteve rastrskih ploščic.';

  @override
  String get appSettings_offlineMapCache => 'Shramba zemljevidov brez povezave';

  @override
  String get appSettings_unitsTitle => 'Enote';

  @override
  String get appSettings_unitsMetric => 'Metrična (m/km)';

  @override
  String get appSettings_unitsImperial => 'Imperialno (ft / mi)';

  @override
  String get appSettings_noAreaSelected => 'Območje ni izbrano';

  @override
  String appSettings_areaSelectedZoom(int minZoom, int maxZoom) {
    return 'Izbrano območje (povečava $minZoom-$maxZoom)';
  }

  @override
  String get appSettings_debugCard => 'Razhroščevanje';

  @override
  String get appSettings_appDebugLogging => 'Programski dnevnik';

  @override
  String get appSettings_appDebugLoggingSubtitle =>
      'Dnevnik debug sporočil za odpravljanje težav';

  @override
  String get appSettings_appDebugLoggingEnabled =>
      'Beleženje napak v aplikaciji omogočeno';

  @override
  String get appSettings_appDebugLoggingDisabled =>
      'Beleženje napak v aplikacije onemogočeno.';

  @override
  String get contacts_title => 'Stiki';

  @override
  String get contacts_noContacts => 'Ni stikov.';

  @override
  String get contacts_contactsWillAppear =>
      'Stiki se bodo prikazali, ko se naprave oglasijo.';

  @override
  String get contacts_unread => 'Neprebrano';

  @override
  String get contacts_searchContactsNoNumber => 'Iskanje stikov...';

  @override
  String contacts_searchContacts(int number, String str) {
    return 'Iskanje stikov...';
  }

  @override
  String contacts_searchFavorites(int number, String str) {
    return 'Iskanje $number$str priljubljenih...';
  }

  @override
  String contacts_searchUsers(int number, String str) {
    return 'Išči $number$str uporabnikov...';
  }

  @override
  String contacts_searchRepeaters(int number, String str) {
    return 'Išči $number$str ponavljalnike...';
  }

  @override
  String contacts_searchRoomServers(int number, String str) {
    return 'Išči $number$str strežnikov sob...';
  }

  @override
  String get contacts_noUnreadContacts => 'Ne prebrani stiki.';

  @override
  String get contacts_noContactsFound => 'Stiki niso najdeni.';

  @override
  String get contacts_storageFull =>
      'Pomnilnik stikov v vozlišču je poln. Novih vozlišč ni mogoče dodati, dokler ne odstranite stikov.';

  @override
  String get contacts_deleteContact => 'Izbriši stik';

  @override
  String contacts_removeConfirm(String contactName) {
    return 'Izbrišem $contactName iz stikov?';
  }

  @override
  String get contacts_removeFromContacts => 'Odstrani iz stikov';

  @override
  String contacts_removeFromContactsConfirm(String contactName) {
    return '$contactName bo prestavljen med odkriti stike. Zgodovina klepeta bo izbrisana.';
  }

  @override
  String get contacts_keepChatHistory => 'Ohrani zgodovino klepeta';

  @override
  String get contacts_remove => 'Odstrani';

  @override
  String contacts_discoveredNearby(int count) {
    return 'Odkriti v bližini ($count)';
  }

  @override
  String get contacts_noContactsDiscoveredHint =>
      'Vozlišča, ki jih vaše radio sliši, še pa niste dodali, so navedena med odkritimi stiki';

  @override
  String get contacts_manageRepeater => 'Upravljaj Ponovitve';

  @override
  String get contacts_manageRoom => 'Upravljajte strežnik sobe';

  @override
  String get contacts_roomLogin => 'Prijava v sobo';

  @override
  String get contacts_openChat => 'Odpri klepet';

  @override
  String get contacts_editGroup => 'Uredi skupino';

  @override
  String get contacts_deleteGroup => 'Izbriši skupino';

  @override
  String contacts_deleteGroupConfirm(String groupName) {
    return 'Izbriši $groupName?';
  }

  @override
  String get contacts_newGroup => 'Nova skupina';

  @override
  String get contacts_moreOptions => 'Več možnosti';

  @override
  String get contacts_searchOpen => 'Iskanje kontaktov';

  @override
  String get contacts_searchClose => 'Izklopi iskanje';

  @override
  String get contacts_groupName => 'Ime skupine';

  @override
  String get contacts_groupNameRequired => 'Ime skupine je obvezno.';

  @override
  String get contacts_groupNameReserved => 'To ime skupine je rezervirano';

  @override
  String contacts_groupAlreadyExists(String name) {
    return 'Skupina \"$name\" že obstaja';
  }

  @override
  String get contacts_filterContacts => 'Filtriraj stik\\,...';

  @override
  String get contacts_noContactsMatchFilter =>
      'Noben stik ne ustreza vašemu kriteriju.';

  @override
  String get contacts_noMembers => 'Ni članov.';

  @override
  String get contacts_lastSeenNow => 'Nazadnje viden zdaj';

  @override
  String contacts_lastSeenMinsAgo(int minutes) {
    return 'Zadnjič viden pred $minutes minutami';
  }

  @override
  String get contacts_lastSeenHourAgo => 'Zadnjič viden pred 1 uro.';

  @override
  String contacts_lastSeenHoursAgo(int hours) {
    return 'Zadnjič viden pred $hours urami';
  }

  @override
  String get contacts_lastSeenDayAgo => 'Zadnjič viden pred 1 dnem';

  @override
  String contacts_lastSeenDaysAgo(int days) {
    return 'Zadnjič viden pred $days dnem';
  }

  @override
  String get contact_info => 'Kontaktni podatki';

  @override
  String get contact_settings => 'Nastavitve stika';

  @override
  String get contact_telemetry => 'Telemetrija';

  @override
  String get contact_lastSeen => 'Zadnjič videno';

  @override
  String get contact_clearChat => 'Počisti klepet';

  @override
  String get contact_teleBase => 'Baza telemetrije';

  @override
  String get contact_teleBaseSubtitle =>
      'Dovoli deljenje stanja baterije in osnovne telemetrije';

  @override
  String get contact_teleLoc => 'Lokacija telemetrije';

  @override
  String get contact_teleLocSubtitle => 'Dovoli deljenje podatkov o lokaciji';

  @override
  String get contact_teleEnv => 'Okolje telemetrije';

  @override
  String get contact_teleEnvSubtitle =>
      'Dovoli deljenje podatkov okoljskih senzorjev';

  @override
  String get channels_title => 'Kanali';

  @override
  String get channels_noChannelsConfigured => 'Kanali še niso konfigurirani';

  @override
  String get channels_addPublicChannel => 'Dodaj javni kanal';

  @override
  String get channels_searchChannels => 'Poišči kanale...';

  @override
  String get channels_noChannelsFound => 'Ne najdem kanalov.';

  @override
  String channels_channelIndex(int index) {
    return 'Kanal $index';
  }

  @override
  String get channels_public => 'Javni';

  @override
  String channels_via(String path) {
    return 'via $path';
  }

  @override
  String get channels_private => 'Zasebni';

  @override
  String get channels_hashtag => 'Hashtag';

  @override
  String get channels_addSectionJoin => 'Pridruži obstoječemu';

  @override
  String get channels_addSectionCreate => 'Ustvari novega';

  @override
  String get channels_dragToReorder => 'Povlecite za preureditev';

  @override
  String get channels_editChannel => 'Uredi kanal';

  @override
  String get channels_muteChannel => 'Utišaj kanal';

  @override
  String get channels_unmuteChannel => 'Vklopi obvestila kanala';

  @override
  String get channels_deleteChannel => 'Pošlji kanal';

  @override
  String channels_deleteChannelConfirm(String name) {
    return 'Izbrišem \"$name\"? To se ne da povrniti.';
  }

  @override
  String channels_channelDeleteFailed(String name) {
    return 'Kanala $name ni bilo mogoče izbrisati';
  }

  @override
  String channels_channelDeleted(String name) {
    return 'Kanal \"$name\" izbrisan.';
  }

  @override
  String get channels_addChannel => 'Dodaj Kanal';

  @override
  String get channels_channelIndexLabel => 'Indeks kanala';

  @override
  String get channels_channelName => 'Ime kanala';

  @override
  String get channels_usePublicChannel => 'Uporabi javni kanal';

  @override
  String get channels_standardPublicPsk => 'Standardni javni PSK';

  @override
  String get channels_pskHex => 'PSK (Šestnajstbinska)';

  @override
  String get channels_generateRandomPsk => 'Generiraj naključni PSK';

  @override
  String get channels_enterChannelName => 'Vnesi ime kanala';

  @override
  String get channels_pskMustBe32Hex =>
      'PSK mora biti 32 heksadecimalnih znakov.';

  @override
  String channels_channelAdded(String name) {
    return 'Kanal \"$name\" dodan';
  }

  @override
  String channels_editChannelTitle(int index) {
    return 'Uredi Kanal $index';
  }

  @override
  String get channels_smazCompression => 'Kompresija SMAZ';

  @override
  String get channels_cyr2latCompression => 'Kompresija Cyr2Lat';

  @override
  String get channels_cyr2latCompressionDscr =>
      'Pri pošiljanju nekatere cirilice nadomesti z latiničnimi.';

  @override
  String get channels_cyr2latSettingsHeading => 'Nastavitve Cyr2Lat';

  @override
  String get channels_cyr2latSettingsSubheading => 'Seznam zamenjav';

  @override
  String get channels_cyr2latSettingsDscr =>
      'Uredi JSON-konfiguracijo zamenjav znakov';

  @override
  String get channels_cyr2latSettingsDialogHint => 'JSON-tabela zamenjav';

  @override
  String channels_cyr2latSettingsDialogWrongJSON(Object error) {
    return 'Nepravilen JSON: $error';
  }

  @override
  String channels_channelUpdated(String name) {
    return 'Kanal $name je bil posodobljen';
  }

  @override
  String get settings_cyr2latProfileAdd => 'Dodaj profil Cyr2Lat';

  @override
  String get settings_cyr2latProfileName => 'Ime profila';

  @override
  String get settings_cyr2latProfileNameEmpty =>
      'Ime profila ne sme biti prazno';

  @override
  String get settings_cyr2latProfileAdded => 'Profil je bil uspešno dodan';

  @override
  String get settings_cyr2latProfileUpdated =>
      'Profil je bil uspešno posodobljen';

  @override
  String get settings_cyr2latProfileEdit => 'Uredi profil Cyr2Lat';

  @override
  String get settings_cyr2latProfileDelete => 'Izbriši profil Cyr2Lat';

  @override
  String get settings_cyr2latProfileDeleted => 'Profil je bil uspešno izbrisan';

  @override
  String settings_cyr2latProfileDeleteDscr(String name) {
    return 'Ali res želite izbrisati profil \"$name\"?';
  }

  @override
  String get channels_publicChannelAdded => 'javna skupnost dodana';

  @override
  String get channels_noFreeSlots => 'Vsa mesta za kanale so zasedena';

  @override
  String get channels_sortBy => 'Sortiraj po';

  @override
  String get channels_sortManual => 'Ročno';

  @override
  String get channels_sortAZ => 'A do Z';

  @override
  String get channels_sortLatestMessages => 'Najnovejše sporočilo';

  @override
  String get channels_sortUnread => 'Nerešeno';

  @override
  String get channels_createPrivateChannel => 'Ustvari zasebno kanal.';

  @override
  String get channels_createPrivateChannelDesc =>
      'Varno zaklenjeno s skrivnim ključem.';

  @override
  String get channels_joinPrivateChannel => 'Pridružite se zasebni skupini';

  @override
  String get channels_joinPrivateChannelDesc => 'Ročno vnesite zaporni ključ.';

  @override
  String get channels_shareQr => 'Share as QR code';

  @override
  String channels_shareQrTitle(String name) {
    return 'Share $name';
  }

  @override
  String get channels_shareQrInstructions =>
      'Scan with MeshCore Open TAK (Add channel > Join a Private Channel > Scan QR code) to join this channel.';

  @override
  String get channels_shareQrWarning =>
      'Anyone who scans this code can read and post in this channel. Only show it to people you trust.';

  @override
  String get channels_copyLink => 'Copy link';

  @override
  String get channels_linkCopied => 'Channel link copied';

  @override
  String get channels_scanChannelQr => 'Scan QR code';

  @override
  String get channels_scanChannelQrTitle => 'Scan Channel QR';

  @override
  String get channels_scanChannelQrInstructions =>
      'Point the camera at a channel QR code';

  @override
  String get channels_invalidChannelQr => 'Not a MeshCore channel QR code';

  @override
  String get channels_joinPublicChannel => 'Pridružite se javnemu kanalu';

  @override
  String get channels_joinPublicChannelDesc =>
      'Kdor karkoli je, lahko se pridruži tej skupini.';

  @override
  String get channels_joinHashtagChannel => 'Pridružite se Kanalu z Hashtagom';

  @override
  String get channels_joinHashtagChannelDesc =>
      'Kdor karkoli, lahko se pridruži hashtag kanalom.';

  @override
  String get channels_scanQrCode => 'Skeniraj QR kodo';

  @override
  String get channels_scanQrCodeComingSoon => 'Prihajajoča';

  @override
  String get channels_enterHashtag => 'Vnesite hashtag';

  @override
  String get channels_hashtagHint => 'npr. #ekipa';

  @override
  String channels_regionSetTo(String region) {
    return 'Osebno: $region';
  }

  @override
  String get channels_regionNotSet => 'Region: brak';

  @override
  String get channels_regionSelect_Title => 'Vablajte region';

  @override
  String get channels_clearRegion => 'Jasna regija';

  @override
  String get channels_regionDefaultSuffix => '(privzeta)';

  @override
  String get channels_regionRadioDefaultSuffix => '(privzeto za radio)';

  @override
  String channels_regionRadioDefaultApplies(String region) {
    return 'To radio pošilja flood sporočila brez regije v svoji privzeti regiji: $region.';
  }

  @override
  String get channels_regionSelectExplanation =>
      'Sporočila flood na tem kanalu bodo posredovana samo s ponovitelji iz izbrane regije.';

  @override
  String get channels_regionEmpty => 'Regij še ni.';

  @override
  String get channels_manageRegions => 'Upravljaj regije';

  @override
  String get chat_noMessages => 'Še ni sporočil.';

  @override
  String get chat_sendMessage => 'Pošlji sporočilo';

  @override
  String chat_sendMessageTo(String contactName) {
    return 'Pošlji sporočilo $contactName';
  }

  @override
  String get chat_sendMessageToStart => 'Pošlji sporočilo za začetek.';

  @override
  String get chat_originalMessageNotFound =>
      'Opozorilo: Sporočilo ni bilo najdeno';

  @override
  String chat_replyingTo(String name) {
    return 'Odgovarjanje $name';
  }

  @override
  String chat_replyTo(String name) {
    return 'Odpošlji odgovor $name';
  }

  @override
  String get chat_location => 'Lokacija';

  @override
  String get chat_typeMessage => 'Vnesi sporočilo...';

  @override
  String get chat_futureTimestampWarning =>
      'Čas tega sporočila je v prihodnosti, zato je ura pošiljatelja morda napačna. Prikazano je v vrstnem redu prispetja.';

  @override
  String chat_messageTooLong(int maxBytes) {
    return 'Pošiljanje sporočila je onemogočeno, saj je preveliko (maksimalno $maxBytes byte-ov).';
  }

  @override
  String get chat_messageCopied => 'Sporočilo poslano';

  @override
  String get chat_messageDeleted => 'Sporočilo izbrisano';

  @override
  String get chat_retryingMessage => 'Ponovni poskus.';

  @override
  String chat_retryCount(int current, int max) {
    return 'Ponovit $current/$max';
  }

  @override
  String get chat_selectSendAction => 'Izberite dejanje pošiljanja';

  @override
  String get chat_sendGif => 'Pošlji GIF';

  @override
  String get chat_shareMyLocation => 'Deli mojo lokacijo';

  @override
  String get chat_noRadioLocation => 'Vaš radio nima nastavljene lokacije';

  @override
  String get chat_removeGif => 'Odstrani GIF';

  @override
  String get chat_cancelReply => 'Prekliči odgovor';

  @override
  String get chat_sendImageLora => 'Pošlji sliko prek MeshCore';

  @override
  String get chat_imagePickFailed => 'Nispeval sem tega ta slik';

  @override
  String get chat_receivedGif => 'Otrvljen GIF';

  @override
  String get chat_reply => 'Odgovori';

  @override
  String get chat_addReaction => 'Dodaj reakcijo';

  @override
  String get chat_me => 'jaz';

  @override
  String get reaction_report => 'Emoji reakcije';

  @override
  String get emojiCategorySmileys => 'Emoji';

  @override
  String get emojiCategoryGestures => 'Gestikulacije';

  @override
  String get emojiCategoryHearts => 'Srce';

  @override
  String get emojiCategoryObjects => 'Predmeti';

  @override
  String get gifPicker_title => 'Izberi GIF';

  @override
  String get gifPicker_searchHint => 'Išči GIF-e...';

  @override
  String get gifPicker_poweredBy => 'Napredno z GIPHY';

  @override
  String get gifPicker_noGifsFound => 'Ne najdem GIF-ov.';

  @override
  String get gifPicker_failedLoad => 'Neuspešno nalaganje GIF-a';

  @override
  String get gifPicker_failedSearch => 'Iskanje neuspešno.';

  @override
  String get gifPicker_noInternet => 'Ni internetne povezave';

  @override
  String get debugLog_appTitle => 'Log zapiske aplikacije';

  @override
  String get debugLog_bleTitle => 'Log zapis BLE';

  @override
  String get debugLog_copyLog => 'Kopiraj dnevnik';

  @override
  String get debugLog_clearLog => 'Briši log';

  @override
  String get debugLog_copied => 'Beležka kopirana.';

  @override
  String get debugLog_bleCopied => 'Kopirana beležka iz BLE';

  @override
  String get debugLog_noEntries => 'Ni ustvarjenih debug zapisov.';

  @override
  String get debugLog_enableInSettings =>
      'Omogoči beleženje napak v nastavitvah aplikacije';

  @override
  String get debugLog_frames => 'Okvirji';

  @override
  String get debugLog_rawLogRx => 'Svež Log-RX';

  @override
  String get debugLog_noBleActivity => 'Ni BLE aktivnosti.';

  @override
  String debugFrame_length(int count) {
    return 'Izhodni rob: $count bajtov';
  }

  @override
  String debugFrame_command(String value) {
    return 'Navodilo: 0x$value';
  }

  @override
  String get debugFrame_textMessageHeader => 'Obvestilo:';

  @override
  String debugFrame_destinationPubKey(String pubKey) {
    return '- Destinirano Ključno Besedilo: $pubKey';
  }

  @override
  String debugFrame_timestamp(int timestamp) {
    return '- Časovnik: $timestamp';
  }

  @override
  String debugFrame_flags(String value) {
    return '- Ploki: 0x$value';
  }

  @override
  String debugFrame_textType(int type, String label) {
    return '- Tip besedila: $type ($label)';
  }

  @override
  String get debugFrame_textTypeCli => 'CLI (Command Line Interface)';

  @override
  String get debugFrame_textTypePlain => 'Preprosto';

  @override
  String debugFrame_text(String text) {
    return '- Tekst: \"$text\"';
  }

  @override
  String get debugFrame_hexDump => 'Izpis heksadecimalnih vrednosti:';

  @override
  String chat_hopsCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'skoki',
      one: 'skok',
    );
    return '$count $_temp0';
  }

  @override
  String get chat_removePath => 'Izbriši pot';

  @override
  String get chat_noPathHistoryYet =>
      'Ni shranjenih poti.\nPošlji sporočilo za odkrivanje poti.';

  @override
  String get chat_pathCleared =>
      'Pot je očiščena. Naslednje sporočilo bo ponovno odkril pot.';

  @override
  String get chat_fullPath => 'Polna pot';

  @override
  String get routing_title => 'Navigacija';

  @override
  String get routing_modeAuto => 'Avto';

  @override
  String get routing_modeFlood => 'Flood';

  @override
  String get routing_modeManual => 'Navodilo';

  @override
  String get routing_modeAutoHint =>
      'Samodejno izbere najbolj poznano pot, in sicer, ko ni na voljo nobena.';

  @override
  String get routing_modeFloodHint =>
      'Prenosi preko vseh repetitorjev. Najzanesljivejši način, vendar zahteva več časa.';

  @override
  String get routing_modeManualHint =>
      'Vedno sledi natančni poti, ki jo ste določili.';

  @override
  String get routing_currentRoute => 'Trenutna pot';

  @override
  String get routing_directNoHops => 'Neposredno – brez prehodov';

  @override
  String get routing_noPathYet =>
      'Žep trenutno ni mogoče najti. Naslednje sporočilo bo posredovano, dokler ne bo ugotovljeno, kje je pot.';

  @override
  String get routing_floodBroadcast => 'Prenos preko vseh repetitiv';

  @override
  String get routing_editPath => 'Uredi pot';

  @override
  String get routing_forgetPath => 'Pozabi na pot';

  @override
  String get routing_knownPaths => 'Poznati poti';

  @override
  String get routing_knownPathsHint => 'Kliknite na pot, da jo izberete.';

  @override
  String get routing_inUse => 'V uporabi';

  @override
  String get routing_qualityStrong => 'Močan prvi korak';

  @override
  String get routing_qualityGood => 'Prva uspešna faza';

  @override
  String get routing_qualityFair => 'Prva, uspešna faza';

  @override
  String get routing_qualityWorked => 'Izpolnil';

  @override
  String get routing_qualityFlood => 'Slišano prek flooda';

  @override
  String get routing_qualityUntested => 'Ne preizkušen';

  @override
  String routing_lastWorked(String when) {
    return 'delal/a $when';
  }

  @override
  String get routing_neverWorked => 'nikoli ni bilo potrjeno';

  @override
  String routing_deliveryCounts(int successes, int failures) {
    return '$successes delivered, $failures failed';
  }

  @override
  String get routing_floodDelivery => 'Dostava prek flooda';

  @override
  String get pathEditor_title => 'Izgradnja poti';

  @override
  String pathEditor_hopCounter(int count) {
    return '$count od 64 skokov';
  }

  @override
  String get pathEditor_noHops =>
      'Še niso dodani skoki. Za dodajanje skokov v vrstnem redu kliknite na ponovitelje spodaj, ali pa shranite brez dodanih skokov, da ga lahko posredujete neposredno.';

  @override
  String get pathEditor_addHops => 'Dodajte skoke v vrstnem redu.';

  @override
  String get pathEditor_searchRepeaters => 'Iskanje ponovitev';

  @override
  String get pathEditor_advancedHex => 'Napredno: surovi šestnajstni pot';

  @override
  String get pathEditor_hexLabel => 'Predfiks za heksadecimalno šifro';

  @override
  String get pathEditor_hexHelper =>
      'Dva šestbitna znaka na vsak skok, ločena z vejico';

  @override
  String pathEditor_invalidTokens(String tokens) {
    return 'Neveljaven: $tokens';
  }

  @override
  String get pathEditor_tooManyHops => 'Največ 64 hopov';

  @override
  String get pathEditor_usePath => 'Uporabite to poto';

  @override
  String get pathEditor_removeHop => 'Odstranite skok';

  @override
  String get pathEditor_unknownHop => 'Neznani ponovitelj';

  @override
  String get chat_pathSavedLocally =>
      'Shrano lokalno. Povežite se za sinhronizacijo.';

  @override
  String get chat_pathDeviceConfirmed => 'Naprave potrjeno.';

  @override
  String get chat_pathDeviceNotConfirmed => 'Naprave še niso potrdile.';

  @override
  String get chat_type => 'Vnesite';

  @override
  String get chat_path => 'Pot';

  @override
  String get chat_viewPathOnMap => 'Pokaži pot na zemljevidu';

  @override
  String get chat_publicKey => 'Ključ javnega tipa';

  @override
  String get chat_compressOutgoingMessages => 'Stisnite izhodne sporočila';

  @override
  String get chat_floodForced => 'Flood (vsiljeno)';

  @override
  String get chat_directForced => 'Nezglašen (nasilje)';

  @override
  String chat_hopsForced(int count) {
    return '$count skoki (nasilje)';
  }

  @override
  String get chat_floodAuto => 'Flood (samodejno)';

  @override
  String get chat_direct => 'Neposredni';

  @override
  String get chat_poiShared => 'Deljeno točke MN';

  @override
  String chat_unread(int count) {
    return 'Nerešeno: $count';
  }

  @override
  String get chat_markAsUnread => 'Označiti kot neneobdelano';

  @override
  String get chat_newMessages => 'Nove novice';

  @override
  String get chat_today => 'Danes';

  @override
  String get chat_yesterday => 'Včeraj';

  @override
  String get chat_openLink => 'Odpreti povezavo?';

  @override
  String get chat_openLinkConfirmation =>
      'Ali želite odpreti to povezavo v brskalniku?';

  @override
  String get chat_open => 'Odpri';

  @override
  String chat_couldNotOpenLink(String url) {
    return 'Povezave ni bilo mogoče odpreti: $url';
  }

  @override
  String get chat_invalidLink => 'Neveljavna oblika povezave';

  @override
  String get map_title => 'Zemljevid';

  @override
  String get map_searchHint => 'Iščite ime ali ID vozlišča';

  @override
  String get map_activity => 'Dejavnost';

  @override
  String get map_online => 'V omrežju';

  @override
  String get map_recent => 'Nedavni';

  @override
  String get map_stale => 'Zastarelo';

  @override
  String get map_visible => 'Vidno';

  @override
  String get map_hidden => 'Skrit';

  @override
  String get map_centerOnNode => 'Centriraj na vozlišče';

  @override
  String get map_centerOnMe => 'Centriraj na mojo lokacijo';

  @override
  String get map_details => 'Podrobnosti';

  @override
  String get map_noGps => 'Brez GPS';

  @override
  String get map_noResults => 'Ni ujemajočih se vozlišč';

  @override
  String get map_lineOfSight => 'Linija vida';

  @override
  String get map_losScreenTitle => 'Linija vida';

  @override
  String get map_noNodesWithLocation =>
      'Nihče od notranjih elementov nima podatkov o lokaciji.';

  @override
  String get map_noNodesLocationHint =>
      'Ni vozlišč z zadnjo lokacijo. Razširite časovni filter ali v Nastavitvah nastavite svojo lokacijo.';

  @override
  String get map_nodesNeedGps =>
      'Omrežje morajo deliti svoje GPS koordinate,\nda se prikazao na zemljeobrazniku.';

  @override
  String map_nodesCount(int count) {
    return 'Omize: $count';
  }

  @override
  String map_pinsCount(int count) {
    return 'Žigovi: $count';
  }

  @override
  String get map_chat => 'Čistemar';

  @override
  String get map_repeater => 'Ponovitelj';

  @override
  String get map_room => 'Soba';

  @override
  String get map_sensor => 'Senzor';

  @override
  String get map_pinDm => 'Zavežite (DM)';

  @override
  String get map_pinPrivate => 'Zasebno označit';

  @override
  String get map_pinPublic => 'Oznaka (javna)';

  @override
  String get map_lastSeen => 'Zadnjič Zazet';

  @override
  String get map_disconnectConfirm =>
      'Ste prepričani, da želite se odklopiti s tega naprave?';

  @override
  String get map_from => 'Od';

  @override
  String get map_source => 'Vir';

  @override
  String get map_flags => 'Zapestnice';

  @override
  String get map_type => 'Type';

  @override
  String get map_path => 'Path';

  @override
  String get map_location => 'Location';

  @override
  String get map_estLocation => 'Est. Location';

  @override
  String get map_publicKey => 'Public Key';

  @override
  String get map_publicKeyPrefixHint => 'e.g. ab12';

  @override
  String get map_shareMarkerHere => 'Delite točke tukaj.';

  @override
  String get map_setAsMyLocation => 'Nastavite to kot mojo lokacijo';

  @override
  String get map_pinLabel => 'Oznaka za pritrditev';

  @override
  String get map_label => 'Oznaka';

  @override
  String get map_labelUpdateHint =>
      'Če uporabite enako oznako kot prej, se oznaka na zemljevidu posodobi pri prejemnikih MeshCore Open.';

  @override
  String get map_pointOfInterest => 'Točka zanimivosti';

  @override
  String get map_sendToContact => 'Pošlji v kontakt';

  @override
  String get map_sendToChannel => 'Pošlji v kanal';

  @override
  String get map_noChannelsAvailable => 'Nihče kanalov na voljo.';

  @override
  String get map_publicLocationShare => 'Deljenje javne lokacije';

  @override
  String map_publicLocationShareConfirm(String channelLabel) {
    return 'Kljubite boste delili lokacijo v $channelLabel. Ta kanal je javno dostopen in vsak, ki ima PSK, ga lahko vidi.';
  }

  @override
  String get map_connectToShareMarkers =>
      'Povežite se z napravo za deljenje oznak.';

  @override
  String get map_filterNodes => 'Filtirirajte člene';

  @override
  String get map_nodeTypes => 'Vrste knope';

  @override
  String get map_chatNodes => 'Čuti zvezde';

  @override
  String get map_repeaters => 'Ponovljalniki';

  @override
  String get map_otherNodes => 'Druge vozlišča';

  @override
  String get map_rooms => 'Rooms';

  @override
  String get map_sensors => 'Sensors';

  @override
  String get map_showOverlaps => 'Prekrivanje ključa ponovnega predvajanja';

  @override
  String get map_keyPrefix => 'Predpona ključa';

  @override
  String get map_filterByKeyPrefix => 'Filtri po predpomniku ključa';

  @override
  String get map_publicKeyPrefix => 'Predifika javnega ključa';

  @override
  String get map_markers => 'Označitelji';

  @override
  String get map_showSharedMarkers => 'Pokaži skupno označenja';

  @override
  String get map_showGuessedLocations => 'Pokaži lokacije domnevnih not.';

  @override
  String get map_clusterNodes => 'Združi bližnja vozlišča';

  @override
  String get map_groupChip => 'Skupine';

  @override
  String get map_clusterNodesSubtitle =>
      'Pri manjšem povečanju se bližnja vozlišča prikažejo kot en oštevilčen krog';

  @override
  String get map_showDiscoveryContacts => 'Prikaži odkritja kontaktov';

  @override
  String get map_guessedLocation => 'Predpostavljena lokacija';

  @override
  String get map_lastSeenTime => 'Datum zadnjega vpogleda';

  @override
  String get map_sharedPin => 'Deljeno naslovno geslo';

  @override
  String get map_sharedAt => 'Deljeno';

  @override
  String get map_joinRoom => 'Pridružiti sobo';

  @override
  String get map_manageRepeater => 'Upravljajte Ponovitve';

  @override
  String get map_manageServer => 'Upravljaj strežnik';

  @override
  String get map_tapToAdd => 'Pritisnite na vozlišča, da jih dodate poti.';

  @override
  String get map_runTrace => 'Zaženi sledenje poti';

  @override
  String get map_runTraceWithReturnPath => 'Vrni se nazaj po isti poti.';

  @override
  String get map_removeLast => 'Odstrani Zadnji';

  @override
  String get map_pathTraceCancelled => 'Spremljanje poti je prekinjeno.';

  @override
  String get mapCache_title =>
      'Omrezni predpomnilnik zemljeških zemljejevskih slik';

  @override
  String get mapCache_selectAreaFirst =>
      'Izberite območje za prvo predpomnilnik.';

  @override
  String get mapCache_noTilesToDownload =>
      'Nihče slik ne bo naložil za to območje.';

  @override
  String get mapCache_downloadTilesTitle => 'Naloži ploščice';

  @override
  String mapCache_downloadTilesPrompt(int count) {
    return 'Naložiť $count plošč za uporabo v režimu brez povezave?';
  }

  @override
  String get mapCache_downloadAction => 'Naloži';

  @override
  String mapCache_cachedTiles(int count) {
    return 'Pospešeno shranjeni $count plošč';
  }

  @override
  String mapCache_cachedTilesWithFailed(int downloaded, int failed) {
    return 'Shranjeni $downloaded ploščad ($failed neuspešno)';
  }

  @override
  String get mapCache_clearOfflineCacheTitle =>
      'Ponovite arhiv za offline način';

  @override
  String get mapCache_clearOfflineCachePrompt =>
      'Izbriši vse predpomnilnikovane kartografske ploščice?';

  @override
  String get mapCache_offlineCacheCleared =>
      'Omrezni predpomnik je bil izbrisal.';

  @override
  String get mapCache_noAreaSelected => 'Nizona označena površina';

  @override
  String get mapCache_cacheArea => 'Omanski prostor';

  @override
  String get mapCache_useCurrentView => 'Uporabi trenutni prikaz';

  @override
  String get mapCache_zoomRange => 'Občutek razpona';

  @override
  String mapCache_estimatedTiles(int count) {
    return 'Predvideni ploščadi: $count';
  }

  @override
  String mapCache_downloadedTiles(int completed, int total) {
    return 'Naloženo $completed / $total';
  }

  @override
  String get mapCache_downloadTilesButton => 'Naloži ploščice';

  @override
  String get mapCache_clearCacheButton => 'Ponoviti arhiv';

  @override
  String mapCache_failedDownloads(int count) {
    return 'Poslovniški izniki: $count';
  }

  @override
  String get mapCache_cachedTilesLabel => 'Cached tiles';

  @override
  String get mapCache_cachedTileSummaryLabel => 'Cached tile summary';

  @override
  String mapCache_bulkDownloadDisabledForSource(String source) {
    return 'Offline bulk downloads are disabled for $source.';
  }

  @override
  String mapCache_bulkDownloadDisabledInConfig(String source) {
    return 'Offline bulk downloads are disabled for $source in this app configuration.';
  }

  @override
  String mapCache_summarySource(String source) {
    return 'Source: $source';
  }

  @override
  String mapCache_summaryCachedTilesForSource(int count) {
    return 'Cached tiles for source: $count';
  }

  @override
  String mapCache_summaryCachedInSelection(int count) {
    return 'Cached in selected area/zoom: $count';
  }

  @override
  String mapCache_summaryApproxCacheSize(String size) {
    return 'Approx cache size: $size';
  }

  @override
  String mapCache_boundsLabel(
    String north,
    String south,
    String east,
    String west,
  ) {
    return 'N $north, S $south, E $east, W $west';
  }

  @override
  String get time_justNow => 'Takoj';

  @override
  String time_minutesAgo(int minutes) {
    return '$minutes minut nazaj';
  }

  @override
  String time_hoursAgo(int hours) {
    return '${hours}h nazaj';
  }

  @override
  String time_daysAgo(int days) {
    return '$days dni nazaj';
  }

  @override
  String get time_hour => 'ure';

  @override
  String get time_hours => 'ure';

  @override
  String get time_day => 'dan';

  @override
  String get time_days => 'dani';

  @override
  String get time_week => 'teden';

  @override
  String get time_weeks => 'tedne';

  @override
  String get time_month => 'mesec';

  @override
  String get time_months => 'mesi';

  @override
  String get time_minutes => 'minute';

  @override
  String get time_allTime => 'Vse časovno obdobje';

  @override
  String get dialog_disconnect => 'Odklopiti';

  @override
  String get dialog_disconnectConfirm =>
      'Ste prepričani, da želite se odklopiti s tega naprave?';

  @override
  String get login_repeaterLogin => 'Ponovni vnos';

  @override
  String get login_roomLogin => 'Vnos v sobo';

  @override
  String get login_password => 'Geslo';

  @override
  String get login_enterPassword => 'Vnesite geslo';

  @override
  String get login_showPassword => 'Prikaži geslo';

  @override
  String get login_hidePassword => 'Skrij geslo';

  @override
  String get login_savePassword => 'Shrani geslo';

  @override
  String get login_savePasswordSubtitle =>
      'Geslo bo shranjeno varno na tem pripravem.';

  @override
  String get login_repeaterDescription =>
      'Vnesite geslo za ponovljalnik, da dostopite do nastavitev in statusa.';

  @override
  String get login_roomDescription =>
      'Vnesite geslo v sobo za dostop do nastavitev in statusa.';

  @override
  String get login_advanced => 'Napredno';

  @override
  String get login_routing => 'Usmerjanje';

  @override
  String get login_routingMode => 'Navodilo za usmerjevalni način';

  @override
  String get login_autoUseSavedPath => 'Avto (uporabi shranjeno pot)';

  @override
  String get login_forceFloodMode => 'Vsili flood način';

  @override
  String get login_managePaths => 'Upravljajte Potniške Proti';

  @override
  String get login_login => 'Prijava';

  @override
  String login_attempt(int current, int max) {
    return 'Poskušajo $current/$max';
  }

  @override
  String login_failed(String error) {
    return 'Prijava je bila neuspešna: $error';
  }

  @override
  String get login_failedMessage =>
      'Prijava je bila neuspešna. Geslo je napačno ali pa je repetitor nedosegljiv.';

  @override
  String get common_reload => 'Ponovno naloži';

  @override
  String get common_clear => 'Ponoviti';

  @override
  String get common_clearSearch => 'Počisti iskanje';

  @override
  String get path_currentPathLabel => 'Trenutna pot';

  @override
  String get path_noRepeatersFound =>
      'Ne najdenih ponoviteljev ali strežnikov sob.';

  @override
  String get repeater_management => 'Upravljanje ponovitve';

  @override
  String get room_management => 'Upravljanje stremlišča';

  @override
  String get repeater_guest => 'Informacije o ponovljalniku';

  @override
  String get room_guest => 'Informacije o strežniku';

  @override
  String get repeater_managementTools => 'Upravne orodje';

  @override
  String get repeater_guestTools => 'Naložila za goste';

  @override
  String get repeater_roleAdmin => 'ADMIN';

  @override
  String get repeater_roleGuest => 'GOST';

  @override
  String get repeater_status => 'Stanje';

  @override
  String get repeater_statusSubtitle =>
      'Pogledati stanje, statistike in sosede repeatera';

  @override
  String get repeater_telemetry => 'Telemetrija';

  @override
  String get repeater_telemetrySubtitle =>
      'Pogledate telemetrijo senzorjev in sistemske statistike';

  @override
  String get repeater_cli => 'CLI (Command Line Interface)';

  @override
  String get repeater_cliSubtitle =>
      'Pošlji ukazne povelje na ponovitveno enoto.';

  @override
  String get repeater_neighbors => 'Sosedi';

  @override
  String get repeater_neighborsSubtitle => 'Pogledati nič sosednjih skokov.';

  @override
  String get repeater_settings => 'Nastavitve';

  @override
  String get repeater_settingsSubtitle =>
      'Konfigurirajte parametre ponovitelja';

  @override
  String get repeater_clockSyncAfterLogin => 'Sinhronizacija ure po prijavi';

  @override
  String get repeater_clockSyncAfterLoginSubtitle =>
      'Samodejno po uspešnem vstopu pošljite obvestilo o sinhronizaciji časa.';

  @override
  String get repeater_statusTitle => 'Status ponovitelja';

  @override
  String get repeater_routingMode => 'Navodilo za usmerjevalni način';

  @override
  String get repeater_refresh => 'Ponovno obnavljati';

  @override
  String get repeater_statusRequestTimeout => 'Zahtev statusa je iztekla.';

  @override
  String repeater_errorLoadingStatus(String error) {
    return 'Napaka pri obnašanju: $error';
  }

  @override
  String get repeater_systemInformation => 'Informacije o sistemu';

  @override
  String get repeater_battery => 'Baterija';

  @override
  String get repeater_clockAtLogin => 'Ure (pri prijavi)';

  @override
  String get repeater_uptime => 'Čas delovanja';

  @override
  String get repeater_queueLength => 'Dolžina čakalne vrste';

  @override
  String get repeater_debugFlags => 'Nastavitve odpravilnosti';

  @override
  String get repeater_radioStatistics => 'Radio Statistika';

  @override
  String get repeater_lastRssi => 'Potredno RSSI';

  @override
  String get repeater_lastSnr => 'Nazadnje zabeležena SNR';

  @override
  String get repeater_noiseFloor => 'Šumovita raven';

  @override
  String get repeater_txAirtime => 'TX Airtime';

  @override
  String get repeater_rxAirtime => 'RX Airtime';

  @override
  String get repeater_chanUtil => 'Uporaba kanala';

  @override
  String get repeater_packetStatistics => 'Statistika paketa';

  @override
  String get repeater_sent => 'Pošljeno';

  @override
  String get repeater_received => 'Prejeto';

  @override
  String get repeater_duplicates => 'Duplikati';

  @override
  String repeater_daysHoursMinsSecs(
    int days,
    int hours,
    int minutes,
    int seconds,
  ) {
    return '$days dni ${hours}h ${minutes}m ${seconds}s';
  }

  @override
  String repeater_packetTxTotal(int total, String flood, String direct) {
    return 'Skupno: $total, Flood: $flood, Neposredno: $direct';
  }

  @override
  String repeater_packetRxTotal(int total, String flood, String direct) {
    return 'Skupno: $total, Flood: $flood, Neposredno: $direct';
  }

  @override
  String repeater_duplicatesFloodDirect(String flood, String direct) {
    return 'Flood: $flood, Neposredni: $direct';
  }

  @override
  String repeater_duplicatesTotal(int total) {
    return 'Skupno: $total';
  }

  @override
  String get repeater_settingsTitle => 'Nastavitve ponovitelja';

  @override
  String get repeater_basicSettings => 'Osnovne nastavitve';

  @override
  String get repeater_repeaterName => 'Ime ponovitelja';

  @override
  String get repeater_repeaterNameHelper => 'Prikaz imena za ta ponovitelj.';

  @override
  String get repeater_adminPassword => 'Admin geslo';

  @override
  String get repeater_adminPasswordHelper => 'Polni dostopno geslo';

  @override
  String get repeater_guestPassword => 'Geslo gostača';

  @override
  String get repeater_guestPasswordHelper => 'Odpovedni dostopni geslo';

  @override
  String get repeater_radioSettings => 'Nastavitve Radija';

  @override
  String get repeater_frequencyMhz => 'Frekvenca (MHz)';

  @override
  String get repeater_frequencyHelper => '300–2500 MHz';

  @override
  String get repeater_txPower => 'TX Moč';

  @override
  String get repeater_txPowerHelper => '1-30 dBm';

  @override
  String get repeater_bandwidth => 'Pasovna širina';

  @override
  String get repeater_spreadingFactor => 'Razširitveni faktor';

  @override
  String get repeater_codingRate => 'Programska hitrost';

  @override
  String get repeater_locationSettings => 'Nastavitve lokacije';

  @override
  String get repeater_latitude => 'Širina';

  @override
  String get repeater_latitudeHelper => 'Desetbinske protiure (npr. 37.7749)';

  @override
  String get repeater_longitude => 'Dolžina';

  @override
  String get repeater_longitudeHelper =>
      'Desetbinske protiure (npr. -122,4194)';

  @override
  String get repeater_features => 'Značilnosti';

  @override
  String get repeater_packetForwarding => 'Usmerjanje paketa';

  @override
  String get repeater_packetForwardingSubtitle =>
      'Omogoči ponovitelja za usmerjanje paketov.';

  @override
  String get repeater_guestAccess => 'Prijemnik';

  @override
  String get repeater_guestAccessSubtitle =>
      'Omogoči dostop gostom v samo bralni načinu.';

  @override
  String get repeater_privacyMode => 'Privatni način';

  @override
  String get repeater_privacyModeSubtitle => 'Skrita imena/lokacije v oglasih';

  @override
  String get repeater_advertisementSettings => 'Nastavitve oglasnika';

  @override
  String get repeater_localAdvertInterval => 'Lokalen Oglasovni Razpon';

  @override
  String repeater_localAdvertIntervalMinutes(int minutes) {
    return '$minutes minut';
  }

  @override
  String get repeater_floodAdvertInterval => 'Razpon Flood Oglasov';

  @override
  String repeater_floodAdvertIntervalHours(int hours) {
    return '$hours ur';
  }

  @override
  String get repeater_encryptedAdvertInterval =>
      'Šifrirana Oglasovalska Trajanje';

  @override
  String get repeater_dangerZone => 'Opozorilo';

  @override
  String get repeater_rebootRepeater => 'Ponovni zagon Repeaterja';

  @override
  String get repeater_rebootRepeaterSubtitle => 'Ponovni zagon ponovitelja.';

  @override
  String get repeater_rebootRepeaterConfirm =>
      'Ste prepričani, da želite ponovno zagon tega ponovitelja?';

  @override
  String get repeater_regenerateIdentityKey => 'Ponovite Ključ Identnosti';

  @override
  String get repeater_regenerateIdentityKeySubtitle =>
      'Ustvarite novo par javnih/zasebnih ključev';

  @override
  String get repeater_regenerateIdentityKeyConfirm =>
      'To bo ustvaril novo identiteto za ponavljalnik. Prijavite se?';

  @override
  String get repeater_eraseFileSystem => 'Počisti Sustav Vajah';

  @override
  String get repeater_eraseFileSystemSubtitle =>
      'Oblikuj datoteko ponovitve sistema';

  @override
  String get repeater_eraseFileSystemConfirm =>
      'OPOZORILO: To bo izbrisal/a vsa dejstva na ponovilu. To ni mogoče povzvrniti!';

  @override
  String get repeater_eraseSerialOnly =>
      'Brisanje je na voljo samo preko serijske konzole.';

  @override
  String repeater_commandSent(String command) {
    return 'Navodilo poslano: $command';
  }

  @override
  String repeater_errorSendingCommand(String error) {
    return 'Napaka pri pošiljanju ukaznega: $error';
  }

  @override
  String get repeater_confirm => 'Potrdit';

  @override
  String get repeater_settingsSaved => 'Nastavitve so shranjene uspešno.';

  @override
  String get repeater_rxGain => 'Povečana dobitka RX';

  @override
  String get repeater_rxGainHelper =>
      'Veća občutljivost, večji porabljeni tok (velja samo za SX1262/SX1268)';

  @override
  String get repeater_refreshRxGain => 'Povečana dobitka RX, posodobit';

  @override
  String get repeater_multiAcks => 'Več potrdil';

  @override
  String get repeater_multiAcksSubtitle =>
      'Potrdite sporočila po več poti za boljši dostop';

  @override
  String get repeater_refreshMultiAcks => 'Ponovite več potrdil';

  @override
  String get repeater_networkHealth => 'Zdravilo omrežja';

  @override
  String get repeater_loopDetect => 'Detekcija ciklov';

  @override
  String get repeater_loopDetectHelper =>
      'Izpišite pakete, ki izgledajo kot pete v omrežju.';

  @override
  String get repeater_loopDetectOff => 'Izklopljeno';

  @override
  String get repeater_loopDetectMinimal => 'Minimalen';

  @override
  String get repeater_loopDetectModerate => 'Umiren';

  @override
  String get repeater_loopDetectStrict => 'Strogi';

  @override
  String get repeater_dutyCycle => 'Ciklus delovanja';

  @override
  String get repeater_dutyCycleHelper =>
      'Najvišji odstotek časa, ki ga lahko posreduje.';

  @override
  String repeater_dutyCyclePercent(int percent) {
    return '$percent %';
  }

  @override
  String get repeater_ownerInfo => 'Informacije o operaterju';

  @override
  String get repeater_ownerInfoHelper => 'javni podatki o tej napravi';

  @override
  String get repeater_refreshOwnerInfo => 'Prejmi informacije o operaterju';

  @override
  String get repeater_floodMax => 'Največji možni odmerek';

  @override
  String get repeater_floodMaxHelper =>
      'Največje število paketov, ki lahko potujejo v enem plovilnem paketu (0-64)';

  @override
  String get repeater_advancedSettings => 'Napredno';

  @override
  String get repeater_advancedSettingsSubtitle =>
      'Gumbi za nastavljanje za izkušene uporabnike';

  @override
  String get repeater_pathHashMode => 'Način ustvarjanja hash-a poti';

  @override
  String get repeater_pathHashModeHelper =>
      'Bajti, uporabljeni za kodiranje ID-ja tega repetitorja v oznakah flood poti/zaznavanja zank. 0=1 bajt (256 ID-jev, do 64 skokov), 1=2 bajta (65.000 ID-jev, do 32 skokov), 2=3 bajti (16 milijonov ID-jev, do 21 skokov). Vdelana programska oprema pred v1.14 je vedno uporabljala 1-bajtne poti; v1.14 in novejše je mogoče nastaviti na 2- ali 3-bajtne poti.';

  @override
  String get repeater_keySettings => 'Zmeničke ključe identitete';

  @override
  String get repeater_keySettingsSubtitle =>
      'Zamenjajte publican ali privatni ključni par';

  @override
  String get repeater_prvKey => 'Privarna ključa';

  @override
  String get repeater_prvKeyHelper =>
      'Nova privatna ključa za prekaznik, 128- znakovni šestnastik.';

  @override
  String get repeater_generatePrvKey => 'Sporočna ključna para';

  @override
  String get repeater_stopGeneratingPrvKey =>
      'Prekajanje odkrivanja ključne paro';

  @override
  String get repeater_pubKey => 'Public key (publična ključa)';

  @override
  String get repeater_pubKeyHelper =>
      'Taj je publicna ključ, ki pomeni pripovedno privatno ključ. Ne možeš to vrediti direktno.';

  @override
  String get repeater_pubKeyPrefix => 'Poželana prefiks';

  @override
  String repeater_pubKeyPrefixHelper(int tries) {
    return 'Najdi publicen ključ, ki začne s tih hexnih čitov. Očekivani pokusi: $tries.';
  }

  @override
  String get repeater_txDelay => 'Flood TX zakasnitev';

  @override
  String get repeater_txDelayHelper =>
      'Uporaba intervalov za ponovno pošiljanje v primeru flood prometa, kot pomnožnik časovne trajanje paketa (0-2, privzeto 0,5). Veje vrednost = manjše kolizije, vendar počasnejše dostavo.';

  @override
  String get repeater_directTxDelay => 'Neposredni časovno odlašanje';

  @override
  String get repeater_directTxDelayHelper =>
      'Razdalja za ponovno pošiljanje za neposredno (neobvezen) promet, kot pomnožnik časovne trajanja paketa (0-2, privzeto 0,3).';

  @override
  String get repeater_intThresh => 'Meja, pri kateri nastane motnja';

  @override
  String get repeater_intThreshHelper =>
      'Tretja stopnja se uporablja za kalibracijo šumnega nivoja radija, kar omogoča, da se izklaplja pri šumu, ki presega to raven. 0 izklopi – uporabite le, če zaznate napake v šumnem pasu.';

  @override
  String get repeater_agcResetInterval => 'Interval ponovne kalibracije AGC';

  @override
  String get repeater_agcResetIntervalHelper =>
      'Kako pogosto je treba ponovno nastaviti samodejno regulacijo občutljivosti, da se vrnete v normalno stanje? Interval je nastavljen na nekaj sekund, natančno na 4. 0 izklopi periodično ponovno nastavljanje.';

  @override
  String get repeater_actionsTitle => 'Dejanja';

  @override
  String get repeater_sendAdvert => 'Pošlji flood oglas';

  @override
  String get repeater_sendAdvertSubtitle =>
      'Razpošlji flood oglas preko omrežja.';

  @override
  String get repeater_sendAdvertZeroHop =>
      'Pošlji oglas, ki ne potrebuje posrednika.';

  @override
  String get repeater_sendAdvertZeroHopSubtitle =>
      'Premejte oglas, ki uporablja eno povezavo (brez posrednikov).';

  @override
  String get repeater_clockSync => 'Sinerizirajte uro zdaj';

  @override
  String get repeater_clockSyncSubtitle =>
      'Nastavite čas na telefonu, da se sinhronizira s repeatrom.';

  @override
  String repeater_actionSucceeded(String action) {
    return '$action je uspel';
  }

  @override
  String repeater_actionFailed(String action, String error) {
    return '$action ni bilo uspešno: $error';
  }

  @override
  String get repeater_settingsSavedRebootNeeded =>
      'Nastavitve shranjene – ponovni zagon repetitorja za uporabo';

  @override
  String repeater_settingsPartialFailure(String failures) {
    return 'Nekatna nastavitva niso uspešna: $failures';
  }

  @override
  String repeater_errorSavingSettings(String error) {
    return 'Napaka pri shranjevanju nastavitev: $error';
  }

  @override
  String get repeater_refreshBasicSettings =>
      'Ponovno nastavi osnovne nastavitve';

  @override
  String get repeater_refreshRadioSettings => 'Ponovno Nastavitve Radija';

  @override
  String get repeater_refreshTxPower => 'Ponovno nastavi TX moč';

  @override
  String get repeater_refreshPacketForwarding =>
      'Ponovno nastavitve usmerjevanja paketa';

  @override
  String get repeater_refreshGuestAccess => 'Ponovno nastavitve dostopa gostov';

  @override
  String get repeater_refreshPrivacyMode =>
      'Ponovno aktiviraj način zasebnosti';

  @override
  String get repeater_refreshAll => 'Osveži vse';

  @override
  String get repeater_settingsNotLoaded =>
      'Nastavitve še niso naložene s tega ponovitelja.';

  @override
  String get repeater_settingsLoadIncomplete =>
      'Nekaterih nastavitev ni bilo mogoče naložiti. Za poskus uporabite gumbe za osvežitev.';

  @override
  String repeater_refreshed(String label) {
    return '$label je bil/a posodobljen/a';
  }

  @override
  String repeater_errorRefreshing(String label) {
    return 'Napaka pri osveževanju $label';
  }

  @override
  String get repeater_cliTitle => 'Ponovitelj CLI';

  @override
  String get repeater_debugNextCommand => 'Popravi naslednje ukazne možnosti';

  @override
  String get repeater_commandHelp => 'Pomoc';

  @override
  String get repeater_clearHistory => 'Ponovi zgodovino';

  @override
  String get repeater_noCommandsSent =>
      'Niti ena ukazne povratne informacije še ni poslana.';

  @override
  String get repeater_typeCommandOrUseQuick =>
      'Vnesite ukaz spodaj ali uporabite hitre ukaze';

  @override
  String get repeater_enterCommandHint => 'Vnesite ukaz...';

  @override
  String get repeater_previousCommand => 'Prejšnji ukaz';

  @override
  String get repeater_nextCommand => 'Naslednja ukazna';

  @override
  String get repeater_enterCommandFirst => 'Vnesite ukaz najprej';

  @override
  String get repeater_cliCommandFrameTitle => 'Okno ukazne vrstice';

  @override
  String repeater_cliCommandError(String error) {
    return 'Napaka: $error';
  }

  @override
  String get repeater_cliQuickGetName => 'Pridobi ime';

  @override
  String get repeater_cliQuickGetRadio => 'Dobiti Radiopravo';

  @override
  String get repeater_cliQuickGetTx => 'Pridobi TX';

  @override
  String get repeater_cliQuickNeighbors => 'Sosedi';

  @override
  String get repeater_cliQuickVersion => 'Različica';

  @override
  String get repeater_cliQuickAdvertise => 'Oglasite';

  @override
  String get repeater_cliQuickClock => 'Ura';

  @override
  String get repeater_cliQuickClockSync => 'Usklajevanje ure';

  @override
  String get repeater_cliQuickDiscovery => 'Odkrijte sosede';

  @override
  String get repeater_cliHelpAdvert => 'Pošlje paket oglasov';

  @override
  String get repeater_cliHelpReboot =>
      'Ponastavi naprave. (Opomba, lahko pride do \'Timeouta\', kar je normalno)';

  @override
  String get repeater_cliHelpClock => 'Prikaže trenutno uro po uri naprave.';

  @override
  String get repeater_cliHelpPassword =>
      'Nastavi novo administracijsko geslo za naprave.';

  @override
  String get repeater_cliHelpVersion =>
      'Prikaže različico naprave in datum izrabe strojne opreme.';

  @override
  String get repeater_cliHelpClearStats =>
      'Ponastavi različne statistične števke na nič.';

  @override
  String get repeater_cliHelpSetAf => 'Nastavi časovni koeficient.';

  @override
  String get repeater_cliHelpSetTx =>
      'Nastavi moč LoRa oddajanja v dBm. (za ponovni zagon za uporabo)';

  @override
  String get repeater_cliHelpSetRepeat =>
      'Omogoči ali onemogoči vlogo ponovitelja za tono.';

  @override
  String get repeater_cliHelpSetAllowReadOnly =>
      '(Osebni strežnik) Če je \'vklopljeno\', potem bo dovoljeno prijavo z praznim geslom, vendar ne bo mogoče objaviti v sobo. (samo branje).';

  @override
  String get repeater_cliHelpSetFloodMax =>
      'Nastavi največje število skokov za vhodni flood paket (če je >= maks, paket ni posredovan)';

  @override
  String get repeater_cliHelpSetIntThresh =>
      'Nastavi Prag Interferencij (v dB). Privzeto je 14. Nastavi na 0 za onemogočitev zaznavanja interferenc kanalov.';

  @override
  String get repeater_cliHelpSetAgcResetInterval =>
      'Nastavi časovno razdaljo za ponovni zagon nadzornika Avtomatske uteži. Nastavi na 0 za onemogočanje.';

  @override
  String get repeater_cliHelpSetMultiAcks =>
      'Omogoči ali onemogoči funkcijo \"dvojakih potrdil\".';

  @override
  String get repeater_cliHelpSetAdvertInterval =>
      'Nastavi časovno obmesto v minutah za pošiljanje lokalnega (brezposrednega) napovednega paketa. Nastavi na 0 za onemogočiti.';

  @override
  String get repeater_cliHelpSetFloodAdvertInterval =>
      'Nastavi časovno obmesto v urah za pošiljanje flood oglasnega paketa. Nastavi na 0 za onemogočanje.';

  @override
  String get repeater_cliHelpSetGuestPassword =>
      'Nastavi/posodobi geslo gosta. (za ponovitve lahko gostov prijavi pošiljajo zahtevo \"Get Stats\")';

  @override
  String get repeater_cliHelpSetName => 'Nastavi ime oglasnika.';

  @override
  String get repeater_cliHelpSetLat =>
      'Nastavi zemljepisno širino oglaševalskega zemljevida (desetdeljne).';

  @override
  String get repeater_cliHelpSetLon =>
      'Nastavi zemljevidno širino oglasnika. (desetdelne stopnje)';

  @override
  String get repeater_cliHelpSetRadio =>
      'Nastavi popolnoma nove radijske parametre in jih shranjuje v nastavitve. Za uporabo je potrebna \"restart\" ukaz.';

  @override
  String get repeater_cliHelpSetRxDelay =>
      'Nastavitve (eksperimentalne) osnova (mora biti > 1 za učinkovanje) za uporabo rahle zakasnitve prejetih paketov, glede na moč signala/rezultat. Nastavite na 0 za onemogočanje.';

  @override
  String get repeater_cliHelpSetTxDelay =>
      'Nastavi faktor, ki se množi s časom delovanja za paket v flood načinu in z randomiziranim sistemom slotov, da odvrne njegovo posredovanje. (da se zmanjša verjetnost kolizij)';

  @override
  String get repeater_cliHelpSetDirectTxDelay =>
      'Ima podobno vrednost kot txdelay, vendar jo lahko uporabite za dodajanje naknadnega zamika pri posredovanju paketov v režimu neposredne prevodi.';

  @override
  String get repeater_cliHelpSetBridgeEnabled => 'Omogoči/Preklopi most.';

  @override
  String get repeater_cliHelpSetBridgeDelay =>
      'Nastavi zamik pred ponovnim poslanjem paketov.';

  @override
  String get repeater_cliHelpSetBridgeSource =>
      'Izberite, ali bodo most ponavljali prejeto ali poslan paket.';

  @override
  String get repeater_cliHelpSetBridgeBaud =>
      'Nastavi hitrost serijske povezave za mostove rs232.';

  @override
  String get repeater_cliHelpSetBridgeSecret =>
      'Nastavi skrivni dostop za mostove ESPNOW.';

  @override
  String get repeater_cliHelpSetAdcMultiplier =>
      'Nastavi prilagoditev faktorja za prilagoditev poravnalnega napetosti baterije (podprt le na izbranih ploščah).';

  @override
  String get repeater_cliHelpTempRadio =>
      'Nastavi začasne radio parametre za določeno časovno obdobje, kar po preteku časa vrne originalne radio parametre. (ne shranjuje v preferencije).';

  @override
  String get repeater_cliHelpSetPerm =>
      'Modificira ACL. Odstrani ustrezen vnos (po predponi pubkeyja), če je \"permissions\" enako nič. Dodaja nov vnos, če je pubkey-hex v celoti in trenutno ni v ACL. Posodobi vnos po ustreznem predponi pubkeyja. Bitje dovoljenj se razlikuje glede na firmware vlogo, vendar so prvi dve bitki: 0 (Gost), 1 (Lezenje samo), 2 (Lezenje in pisanje), 3 (Administrator).';

  @override
  String get repeater_cliHelpGetBridgeType =>
      'Dobrodošli pri izbiri vrste mostu: brez, rs232, espnow';

  @override
  String get repeater_cliHelpLogStart =>
      'Začnete beleženje paketov v datotekovni sistem.';

  @override
  String get repeater_cliHelpLogStop =>
      'Ustavite beleženje paketov v datotečno sistem.';

  @override
  String get repeater_cliHelpLogErase =>
      'Izbriše pakete zapisov iz datotek sistema.';

  @override
  String get repeater_cliHelpNeighbors =>
      'Prikaže seznam drugih ponovnih knopov, do katerih je prišlo preko brezposrednih oglasov. Vsaka vrstica je id-prefix-hex:timestamp:snr-times-4';

  @override
  String get repeater_cliHelpNeighborRemove =>
      'Izbriše prvo ustreznu postavko (po predpomnilku pubkey (heks),) iz seznama sosedov.';

  @override
  String get repeater_cliHelpRegion =>
      '(Serija samo) Navaja vse definirane regije in trenutna dovoljenja za flood.';

  @override
  String get repeater_cliHelpRegionLoad =>
      'Opomba: to je posebna več ukazna pozivna operacija. Vsak naslednji ukaz je ime regije (z lezijami za prikaz hierarhije, z enim ustvarjenim razmislom). Zaključena s pošiljanjem praznega reda/ukaza.';

  @override
  String get repeater_cliHelpRegionGet =>
      'Išče regijo s podanimi imenimi prefiksom (ali \"\\\" za globalni obseg). Odgovori se s \"-> regija-ime (rodič-ime) \'F\'\"';

  @override
  String get repeater_cliHelpRegionPut =>
      'Dodaja ali posodobi regijsko definicijo s podanim imenom.';

  @override
  String get repeater_cliHelpRegionRemove =>
      'Izbriše definicijo regije s podanim imenom. (mora se popolnoma ujemati in ne sme imeti podregij)';

  @override
  String get repeater_cliHelpRegionAllowf =>
      'Nastavi dovoljenje \'Nere\' za podano regijo. (\'\' za globalni/dedni obseg)';

  @override
  String get repeater_cliHelpRegionDenyf =>
      'Odstrani dovoljenje \'F\'lood\' za podano regijo. (OPOZORILO: na tem koraku ni priporočljivo ga uporabljati na globalnem/dednem obsegu!!)';

  @override
  String get repeater_cliHelpRegionHome =>
      'Odgovori z trenutnim \'domovim\' območjem. (Opomba je bila še nujno uporabljena, rezervirano za prihodnost)';

  @override
  String get repeater_cliHelpRegionHomeSet => 'Nastavi regijo \'domov\'.';

  @override
  String get repeater_cliHelpRegionSave =>
      'Shrani seznam/ zemljevzemi regij v shranjevanje.';

  @override
  String get repeater_cliHelpGps =>
      'Pokaže status GPS-ja. Če je GPS izklopljen, odgovarja samo \"off\", če je vklopljen, odgovarja z \"on\", statusom, \"fix\" in štetjem satelitiv.';

  @override
  String get repeater_cliHelpGpsOnOff => 'Omogoči/onameni GPS način delovanja.';

  @override
  String get repeater_cliHelpGpsSync =>
      'Sinhronizira čas časa ničala z gps uro.';

  @override
  String get repeater_cliHelpGpsSetLoc =>
      'Nastavi položaj časa na GPS koordinate in shranjevanje preferencij.';

  @override
  String get repeater_cliHelpGpsAdvert =>
      'Omogoča konfiguracijo oglasi za notranjost člana:\n- none: ne vključevati lokacije v oglasih\n- share: deliti gps lokacijo (iz SensorManager)\n- prefs: oglaševati lokacijo shranjeno v preferencah';

  @override
  String get repeater_cliHelpGpsAdvertSet =>
      'Nastavi konfiguracijo oglasa na določenem mestu.';

  @override
  String get repeater_commandsListTitle => 'Seznam ukazov';

  @override
  String get repeater_commandsListNote =>
      'Opomba: za različne ukaze \"nastavi ...\" obstaja tudi ukaz \"dobi ...\".';

  @override
  String get repeater_frequencyRangeHelper => '150-2500 MHz';

  @override
  String get repeater_frequencyInvalid => 'Neveljavna frekvenca (150-2500 MHz)';

  @override
  String get repeater_txPowerRangeHelper => '-9 do 30 dBm';

  @override
  String get repeater_recvErrors => 'Napake sprejema';

  @override
  String get room_postsStored => 'Objave';

  @override
  String get room_postsPushed => 'Poslane objave';

  @override
  String get repeater_cliRegionLoadActive =>
      'Način nalaganja regij: pošljite eno ime regije na vrstico, zamaknjeno s presledki pod nadrejeno regijo (dodajte F za imenom, da dovolite flood). Vrstice ne prejmejo odgovora. Pošljite prazno vrstico za konec, nato pa \"region save\", da shranite rezultat.';

  @override
  String get repeater_cliRegionLoadHint =>
      'Vrstica regije ali prazna vrstica za konec';

  @override
  String get repeater_cliRegionLoadEnd => '(konec nalaganja regij)';

  @override
  String get repeater_cliHelpRegionDef =>
      'Definira verigo regij z enim ukazom: vsako ime se doda pod prejšnje; \"name,parent\" doda ime in nato nadaljuje pod navedeno nadrejeno regijo. Odgovori s seznamom regij.';

  @override
  String get repeater_cliHelpSetFloodMaxUnscoped =>
      'Nastavi največje število skokov za posredovanje flood paketov brez določenega regijskega obsega (0-64).';

  @override
  String get repeater_cliHelpSetFloodMaxAdvert =>
      'Nastavi največje število skokov za posredovanje flood oglasov (0-64).';

  @override
  String get repeater_cliHelpGetFloodMaxUnscoped =>
      'Prikaže največje število skokov za flood pakete brez določenega regijskega obsega.';

  @override
  String get repeater_cliHelpGetFloodMaxAdvert =>
      'Prikaže največje število skokov za flood oglase.';

  @override
  String get repeater_cliHelpSetRadioFemRxGain =>
      'Preklopi RX ojačanje (LNA) LoRa front-end modula. Plošče brez njega odgovorijo z \"Error: unsupported\".';

  @override
  String get repeater_cliHelpSetRadioFemTxGain =>
      'Preklopi TX ojačanje (PA) LoRa front-end modula. Plošče brez njega odgovorijo z \"Error: unsupported\".';

  @override
  String get repeater_cliHelpGetRadioFemRxGain =>
      'Prikaže, ali je RX ojačanje LoRa front-end modula vklopljeno.';

  @override
  String get repeater_cliHelpGetRadioFemTxGain =>
      'Prikaže, ali je TX ojačanje LoRa front-end modula vklopljeno.';

  @override
  String get repeater_bridgeNote =>
      'Na voljo samo v vdelani programski opremi, zgrajeni z mostom (RS232 ali ESP-NOW).';

  @override
  String get repeater_general => 'Općenito';

  @override
  String get repeater_settingsCategory => 'Nastavitve';

  @override
  String get repeater_bridge => 'Most';

  @override
  String get repeater_logging => 'Logiranje';

  @override
  String get repeater_neighborsRepeaterOnly => 'Sosedi (le za repetitorje)';

  @override
  String get repeater_regionManagementRepeaterOnly =>
      'Upravljanje regij (zgolj za repetitorje)';

  @override
  String get repeater_regionNote =>
      'Regionske ukazi so bili uvedeni za upravljanje z regijskimi definicijami in dovolili.';

  @override
  String get repeater_gpsManagement => 'Upravljanje GPS';

  @override
  String get repeater_gpsNote =>
      'GPS ukaz je bil uveden za upravljanje z vprašanji, povezanimi z lokacijo.';

  @override
  String get repeater_getCategory => 'Dobite vrednosti';

  @override
  String get repeater_powerMgmt => 'Upravljanje z energijo';

  @override
  String get repeater_sensors => 'Senzori';

  @override
  String get repeater_cliHelpPowerOff =>
      'Izklopi naprave. (ne pričakujemo odziva)';

  @override
  String get repeater_cliHelpClkReboot =>
      'Ponovno nastavi uro na znano točko in ponovno vklopi naprave.';

  @override
  String get repeater_cliHelpAdvertZeroHop =>
      'Pošlje oglas, ki doseže samo neposredne sosede (brez posredovanja).';

  @override
  String get repeater_cliHelpStartOta =>
      'Začne nadstrekovno ažuriranje programne opreme na podprtih ploščah.';

  @override
  String get repeater_cliHelpTime =>
      'Nastavi časovni ukaz naprave na podano število sekund od Unixovega začetka. Časovni ukaz ne more iti nazaj.';

  @override
  String get repeater_cliHelpBoard =>
      'Prikaže proizvajalca plošče / identifikator strojne opreme.';

  @override
  String get repeater_cliHelpDiscoverNeighbors =>
      'Pošlje zahtevo za odkrivanje sosednjih naprav. (Samo za repeatere)';

  @override
  String get repeater_cliHelpPowersaving =>
      'Prikaže, ali je vklopljen način varčevanja z energijo.';

  @override
  String get repeater_cliHelpPowersavingOnOff =>
      'Omogoča ali onemogoča način varčevanja z energijo (če je podprt).';

  @override
  String get repeater_cliHelpErase =>
      '(Samo za serijske naprave) Formira datotapno sistemsko okolje. Izbriše vse nastavitve in kontakte.';

  @override
  String get repeater_cliHelpSetDutyCycle =>
      'Določi maksimalni dovoljeni čas, ki ga naprave lahko posredujejo, v odstotkih (1-100). Samodejno prilagodi faktor, ki odvisen je od časa, ki ga naprave lahko posredujejo.';

  @override
  String get repeater_cliHelpSetPrvKey =>
      '(Samo za serijske naprave) Nadomesti zasebni ključ za identifikacijo naprave. Za uporabo je potrebna ponovna aktivacija. Ustvari nov javni ključ.';

  @override
  String get repeater_cliHelpSetRadioRxGain =>
      '(Samo za SX126x) Vklopi povečano občutljivost RX za izboljšano delovanje pri večjih navorih.';

  @override
  String get repeater_cliHelpSetOwnerInfo =>
      'Določi niz z informacijami o kontaktni osebi, ki je v oglasih. Za uporabo novih vrstic uporabite \'|\'.';

  @override
  String get repeater_cliHelpSetPathHashMode =>
      'Nastavlja način \"hash poti\". 0 = za stare sisteme, 1 = za standard, 2 = za stroge. Vpliva na to, kako so poti uskladene.';

  @override
  String get repeater_cliHelpSetLoopDetect =>
      'Nastavlja občutljivost detekcije ponavljajočih se povezav: izklopljeno, minimalno, umeren, ali strogo.';

  @override
  String get repeater_cliHelpSetFreq =>
      '(Samo za serijske naprave) Hitro nastavi samo frekvenco. Potrebna je ponovna aktivacija. Za popolno nastavitev radio parametrov je priporočljivo uporabiti možnost \"nastavitev radia\".';

  @override
  String get repeater_cliHelpSetBridgeChannel =>
      '(Samo za most ESPNow) Nastavlja kanal WiFi-ja (1-14), ki ga uporablja most.';

  @override
  String get repeater_cliHelpGetName => 'Prikaže ime konfigurirane notranje.';

  @override
  String get repeater_cliHelpGetRole =>
      'Prikaže vlogo programskega oprema (repeater, strežnik za sobo itd.).';

  @override
  String get repeater_cliHelpGetPublicKey => 'Prikazuje javni ključ naprave.';

  @override
  String get repeater_cliHelpGetPrvKey =>
      '(Samo za serijske naprave) Prikazuje zasebni ključ naprave. Sprejemajte ga kot skrivno informacijo.';

  @override
  String get repeater_cliHelpGetRepeat =>
      'Pokaže, ali je omogočeno posredovanje paketov (delovanje kot repetitor).';

  @override
  String get repeater_cliHelpGetTx => 'Prikazuje trenutno moč TX v dBm.';

  @override
  String get repeater_cliHelpGetFreq => 'Prikaže nastavljeno frekvenco v MHz.';

  @override
  String get repeater_cliHelpGetRadio =>
      'Prikaže vse parametre radija: frekvenco, širino pasu, faktor razširjanja, raven kodiranja.';

  @override
  String get repeater_cliHelpGetRadioRxGain =>
      '(Samo za SX126x) Prikazuje stanje povečanega dobiča na RX.';

  @override
  String get repeater_cliHelpGetAf =>
      'Prikazuje trenutni faktor, ki določa časovno obdobje.';

  @override
  String get repeater_cliHelpGetDutyCycle =>
      'Prikazuje trenutno dovoljeno stopnjo delovanja kot odstotek.';

  @override
  String get repeater_cliHelpGetIntThresh =>
      'Prikazuje prag medsebojnega vpliva kanala v dB.';

  @override
  String get repeater_cliHelpGetAgcResetInterval =>
      'Prikazuje interval ponovne kalibracije AGC v sekundah.';

  @override
  String get repeater_cliHelpGetMultiAcks =>
      'Pokaže, ali je vklopljen način dvojnega potrdila (1) ali je izklopljen (0).';

  @override
  String get repeater_cliHelpGetAllowReadOnly =>
      'Pokaže, ali je omogočen le brani dostop za goste.';

  @override
  String get repeater_cliHelpGetAdvertInterval =>
      'Prikazuje časovno obdobje lokalnega oglasa v minutah.';

  @override
  String get repeater_cliHelpGetFloodAdvertInterval =>
      'Prikaže časovno obdobje flood oglasa, v urah.';

  @override
  String get repeater_cliHelpGetGuestPassword =>
      'Prikaže nastavljeno geslo za gostitelja.';

  @override
  String get repeater_cliHelpGetLat => 'Prikaže določeno zemljepisno širino.';

  @override
  String get repeater_cliHelpGetLon => 'Prikaže določeno merilo dolžine.';

  @override
  String get repeater_cliHelpGetRxDelay =>
      'Prikazuje osnovno vrednost RX odlašanja.';

  @override
  String get repeater_cliHelpGetTxDelay =>
      'Prikazuje faktor zamude v flood načinu.';

  @override
  String get repeater_cliHelpGetDirectTxDelay =>
      'Prikazuje faktor odlašanja signala v režimu neposredne komunikacije.';

  @override
  String get repeater_cliHelpGetFloodMax =>
      'Prikazuje največje število skokov za flood.';

  @override
  String get repeater_cliHelpGetOwnerInfo =>
      'Prikazuje niz z informacijami o lastniku.';

  @override
  String get repeater_cliHelpGetPathHashMode =>
      'Prikaže način delovanja z hashjem poti (0/1/2).';

  @override
  String get repeater_cliHelpGetLoopDetect =>
      'Prikazuje občutljivost na zaznavanje ciklov.';

  @override
  String get repeater_cliHelpGetAcl =>
      '(Samo za serije) Navaja vnos za nadzor dostopa na ponovljalniku.';

  @override
  String get repeater_cliHelpGetBridgeEnabled =>
      'Pokaže, ali je most omogočen.';

  @override
  String get repeater_cliHelpGetBridgeDelay =>
      'Prikazuje zamik mosta v milisekundah.';

  @override
  String get repeater_cliHelpGetBridgeSource =>
      'Pokaže, ali most prenaša pakete RX ali TX.';

  @override
  String get repeater_cliHelpGetBridgeBaud =>
      '(Samo za most RS232) Prikazuje hitrost prenosa podatkov na mostu.';

  @override
  String get repeater_cliHelpGetBridgeChannel =>
      '(Samo za most ESPNow) Prikazuje kanal WiFi mosta.';

  @override
  String get repeater_cliHelpGetBridgeSecret =>
      '(Samo za most ESPNow) Prikazuje tajno, ki jo deli most.';

  @override
  String get repeater_cliHelpGetBootloaderVer =>
      '(Samo za NRF52) Prikazuje različico programskega orodja.';

  @override
  String get repeater_cliHelpGetAdcMultiplier =>
      'Prikazuje pomnoževalnik ADC (skaliranje napetosti baterije).';

  @override
  String get repeater_cliHelpGetPwrMgtSupport =>
      'Navaja, ali ima uprava področje za upravljanje z energijo.';

  @override
  String get repeater_cliHelpGetPwrMgtSource =>
      'Prikaže trenutni vir napajanja: zunanji ali baterija.';

  @override
  String get repeater_cliHelpGetPwrMgtBootReason =>
      'Prikazuje najnovejšo razlog za ponovno nastavitve in izklop.';

  @override
  String get repeater_cliHelpGetPwrMgtBootMv =>
      'Prikazuje napetost baterije v mV ob zagonu.';

  @override
  String get repeater_cliHelpSensorGet =>
      'Prebere določeno vrednost senzorja preko tipke.';

  @override
  String get repeater_cliHelpSensorSet =>
      'Ustvari prilagojeno nastavitev za senzor.';

  @override
  String get repeater_cliHelpSensorList =>
      'Navaja vse nastavitve za uporabniške senzorje, razvrščene po želeni začetni indeksu.';

  @override
  String get repeater_cliHelpRegionDefault =>
      'Prikaže trenutno privzeto območje.';

  @override
  String get repeater_cliHelpRegionDefaultSet =>
      'Določi privzeto območje. Za izbris uporabite \"<null>\".';

  @override
  String get repeater_cliHelpRegionListAllowed =>
      'Navaja regije, ki dovoljujejo flood promet.';

  @override
  String get repeater_cliHelpRegionListDenied =>
      'Navaja regije, ki preprečujejo flood promet.';

  @override
  String get repeater_cliHelpStatsPackets =>
      '(Samo za serijske povezave) Prikazuje statistiko na nivoju paketov.';

  @override
  String get repeater_cliHelpStatsRadio =>
      '(Samo za serije) Prikazuje statistične podatke o radiju.';

  @override
  String get repeater_cliHelpStatsCore =>
      '(Samo za serijske naprave) Prikazuje osnovne statistične podatke.';

  @override
  String get telemetry_receivedData => 'Prejeto Telemetrično podatke';

  @override
  String get telemetry_requestTimeout => 'Zahtev telemetrije je iztekla.';

  @override
  String telemetry_errorLoading(String error) {
    return 'Napaka pri obnašanju telemetrije: $error';
  }

  @override
  String get telemetry_noData => 'Niso na voljo podatki o telemetriji.';

  @override
  String telemetry_channelTitle(int channel) {
    return 'Kanal $channel';
  }

  @override
  String get telemetry_batteryLabel => 'Baterija';

  @override
  String get telemetry_voltageLabel => 'Napetost';

  @override
  String get telemetry_mcuTemperatureLabel => 'MCU Temperatura';

  @override
  String get telemetry_temperatureLabel => 'Temperatura';

  @override
  String get telemetry_currentLabel => 'Trenutno';

  @override
  String telemetry_batteryValue(int percent, String volts) {
    return '$percent% / ${volts}V';
  }

  @override
  String telemetry_voltageValue(String volts) {
    return '${volts}V';
  }

  @override
  String telemetry_currentValue(String amps) {
    return '${amps}A';
  }

  @override
  String telemetry_temperatureValue(String celsius, String fahrenheit) {
    return '$celsius°C / $fahrenheit°F';
  }

  @override
  String get telemetry_digitalInputLabel => 'Digitalni vhod';

  @override
  String get telemetry_digitalOutputLabel => 'Digitalni izhod';

  @override
  String get telemetry_analogInputLabel => 'Analogni vhod';

  @override
  String get telemetry_analogOutputLabel => 'Analogni izhod';

  @override
  String get telemetry_genericLabel => 'Splošni senzor';

  @override
  String get telemetry_luminosityLabel => 'Osvetljenost';

  @override
  String get telemetry_presenceLabel => 'Prisotnost';

  @override
  String get telemetry_humidityLabel => 'Vlažnost';

  @override
  String get telemetry_accelerometerLabel => 'Merilnik pospeška';

  @override
  String get telemetry_pressureLabel => 'Tlak';

  @override
  String get telemetry_altitudeLabel => 'Nadmorska višina';

  @override
  String get telemetry_frequencyLabel => 'Frekvenca';

  @override
  String get telemetry_percentageLabel => 'Odstotek';

  @override
  String get telemetry_concentrationLabel => 'Koncentracija';

  @override
  String get telemetry_powerLabel => 'Moč';

  @override
  String get telemetry_distanceLabel => 'Razdalja';

  @override
  String get telemetry_energyLabel => 'Energija';

  @override
  String get telemetry_directionLabel => 'Smer';

  @override
  String get telemetry_timeLabel => 'Čas';

  @override
  String get telemetry_gyrometerLabel => 'Žiroskop';

  @override
  String get telemetry_colourLabel => 'Barva';

  @override
  String get telemetry_gpsLabel => 'GPS';

  @override
  String get telemetry_switchLabel => 'Stikalo';

  @override
  String get telemetry_polylineLabel => 'Polilinija';

  @override
  String telemetry_altitudeValue(String meters) {
    return '$meters m';
  }

  @override
  String telemetry_frequencyValue(String hertz) {
    return '$hertz Hz';
  }

  @override
  String telemetry_pressureValue(String hpa) {
    return '$hpa hPa';
  }

  @override
  String telemetry_luminosityValue(String lux) {
    return '$lux lx';
  }

  @override
  String telemetry_powerValue(String watts) {
    return '$watts W';
  }

  @override
  String telemetry_distanceValue(String meters) {
    return '$meters m';
  }

  @override
  String telemetry_energyValue(String kilowattHours) {
    return '$kilowattHours kWh';
  }

  @override
  String telemetry_directionValue(String degrees) {
    return '$degrees°';
  }

  @override
  String telemetry_concentrationValue(String ppm) {
    return '$ppm ppm';
  }

  @override
  String telemetry_percentageValue(String percent) {
    return '$percent%';
  }

  @override
  String telemetry_analogValue(String value) {
    return '$value';
  }

  @override
  String get telemetry_autoFetchQuantity => 'Število zahtev';

  @override
  String get telemetry_error => 'Podatkov ni bilo mogoče pridobiti';

  @override
  String get neighbors_receivedData => 'Prejeto podatke o sosedih';

  @override
  String get neighbors_requestTimedOut =>
      'Sosedi zahtevajo izklop po dogovoru.';

  @override
  String neighbors_errorLoading(String error) {
    return 'Napaka pri obnašanju sosedov: $error';
  }

  @override
  String get neighbors_repeatersNeighbors => 'Ponovitve Sosedi';

  @override
  String get neighbors_noData => 'Niso na voljo podatki o sosedih.';

  @override
  String neighbors_unknownContact(String pubkey) {
    return 'Nepoznano $pubkey';
  }

  @override
  String neighbors_heardAgo(String time) {
    return 'Udeleženec je prejel sporočilo $time nazaj.';
  }

  @override
  String get channelPath_title => 'Pot do paketa';

  @override
  String get channelPath_viewMap => 'Prikaži zemljeznico';

  @override
  String get channelPath_otherObservedPaths => 'Drugi opazovani poti';

  @override
  String get channelPath_repeaterHops => 'Skoki ponovitelja';

  @override
  String get channelPath_noHopDetails =>
      'Podrobnosti o paketu za dostavo niso navedene.';

  @override
  String get channelPath_messageDetails => 'Podrobnosti sporočila';

  @override
  String get channelPath_senderLabel => 'Pošiljatelj';

  @override
  String get channelPath_timeLabel => 'Ura';

  @override
  String get channelPath_repeatsLabel => 'Ponovitve';

  @override
  String channelPath_pathLabel(int index) {
    return 'Pot $index';
  }

  @override
  String get channelPath_observedLabel => 'Opazovani';

  @override
  String channelPath_observedPathTitle(int index, String hops) {
    return 'Opazovana pot $index • $hops';
  }

  @override
  String get channelPath_noLocationData => 'Nihče ni določil lokacije.';

  @override
  String channelPath_timeWithDate(int day, int month, String time) {
    return '$day/$month $time';
  }

  @override
  String channelPath_timeOnly(String time) {
    return '$time';
  }

  @override
  String get channelPath_unknownPath => 'Neznano';

  @override
  String get channelPath_floodPath => 'Flood';

  @override
  String get channelPath_directPath => 'Neposredni';

  @override
  String channelPath_observedZeroOf(int total) {
    return '0 iz $total skokov';
  }

  @override
  String channelPath_observedSomeOf(int observed, int total) {
    return '$observed iz $total skokov';
  }

  @override
  String get channelPath_mapTitle => 'Potni zemljevid';

  @override
  String get channelPath_noRepeaterLocations =>
      'Ni na voljo nobenih lokacij za ponovitelja za to pot.';

  @override
  String channelPath_primaryPath(int index) {
    return 'Pot $index (Glavni)';
  }

  @override
  String get channelPath_pathLabelTitle => 'Pot';

  @override
  String get channelPath_observedPathHeader => 'Opazovana pot';

  @override
  String channelPath_selectedPathLabel(String label, String prefixes) {
    return '$label • $prefixes';
  }

  @override
  String get channelPath_noHopDetailsAvailable =>
      'Niso na voljo podrobnosti o letu.';

  @override
  String get channelPath_unknownRepeater => 'Nepoznati ponovitelj';

  @override
  String get community_title => 'Skupnost';

  @override
  String get community_create => 'Ustvari skupnost';

  @override
  String get community_createDesc =>
      'Ustvari novo skupnost in jo deli preko QR kode.';

  @override
  String get community_join => 'Pridružiti se';

  @override
  String get community_joinTitle => 'Pridružite se skupnosti';

  @override
  String community_joinConfirmation(String name) {
    return 'Želiš se pridružiti skupnosti \"$name\"?';
  }

  @override
  String get community_scanQr => 'Skeniraj QR kode skupnosti';

  @override
  String get community_scanInstructions =>
      'Nasmerite kamero s skupnostnim QR kodom.';

  @override
  String get community_showQr => 'Pokaži QR kodo';

  @override
  String get community_publicChannel => 'Skupnostna javna';

  @override
  String get community_hashtagChannel => 'Skupnostni hashtag';

  @override
  String get community_name => 'Komunitarne ime';

  @override
  String get community_enterName => 'Vnesite ime skupnosti';

  @override
  String community_created(String name) {
    return 'Skupnost \"$name\" je bila ustvarila.';
  }

  @override
  String community_joined(String name) {
    return 'Prilojen k skupnosti \"$name\"';
  }

  @override
  String get community_qrTitle => 'Delite skupnost';

  @override
  String community_qrInstructions(String name) {
    return 'Skenirajte to QR kodo za vključitev $name.';
  }

  @override
  String get community_hashtagPrivacyHint =>
      'Hashtag kanali skupnosti so dostopni samo članom skupnosti';

  @override
  String get community_invalidQrCode => 'Neveljaven QR koden skupnosti';

  @override
  String get community_alreadyMember => 'Že član';

  @override
  String community_alreadyMemberMessage(String name) {
    return 'Kljub temu ste že član/ka $name.';
  }

  @override
  String get community_addPublicChannel => 'Dodaj Objavni Kanal Komunitarja';

  @override
  String get community_addPublicChannelHint =>
      'Samodejno dodaj javni kanal za to skupnost.';

  @override
  String get community_noCommunities => 'Še nobena skupnost se ni pridružila.';

  @override
  String get community_scanOrCreate =>
      'Skeniraj QR kodo ali ustvari skupnost za začetek.';

  @override
  String get community_manageCommunities => 'Upravljanje skupnosti';

  @override
  String get community_delete => 'Opusti skupnost';

  @override
  String community_deleteConfirm(String name) {
    return 'Zapusti \"$name\"?';
  }

  @override
  String community_deleteChannelsWarning(int count) {
    return 'To bo izbrisalo tudi $count kanal/kanalov in njihova sporočila.';
  }

  @override
  String community_deleted(String name) {
    return 'Zapustil skupnost \"$name\"';
  }

  @override
  String get community_regenerateSecret => 'Ponovno ustvari geslo';

  @override
  String community_regenerateSecretConfirm(String name) {
    return 'Preberite novo tajno geslo za \"$name\"? Vsi članici morajo prebrati novo QR kodo, da lahko nadaljujejo s komunikacijo.';
  }

  @override
  String get community_regenerate => 'Preberi znova';

  @override
  String community_secretRegenerated(String name) {
    return 'Geslo za \"$name\" ponovno ustvarjeno';
  }

  @override
  String get community_updateSecret => 'Ažuriraj ključ';

  @override
  String community_secretUpdated(String name) {
    return 'Skrivnostno spremembo za \"$name\"';
  }

  @override
  String community_scanToUpdateSecret(String name) {
    return 'Skeniraj novo QR kodo za posodabljanje ključa za $name';
  }

  @override
  String get community_addHashtagChannel => 'Dodaj hashtag kanal';

  @override
  String get community_addHashtagChannelDesc =>
      'Dodajte hashtag kanal za to skupnost.';

  @override
  String get community_selectCommunity => 'Izberi skupnost';

  @override
  String get community_regularHashtag => 'Oznaka s hashtagom';

  @override
  String get community_regularHashtagDesc =>
      'javna oznaka (kdorkoli lahko sodeluje)';

  @override
  String get community_communityHashtag => 'Skupnostni hashtag';

  @override
  String get community_communityHashtagDesc =>
      'Izključeno za uporabnike skupnosti';

  @override
  String community_forCommunity(String name) {
    return 'Za $name';
  }

  @override
  String get listFilter_tooltip => 'Filtri in vrstiči';

  @override
  String get listFilter_sortBy => 'Sortiraj po';

  @override
  String get listFilter_latestMessages => 'Najnovejše sporočilo';

  @override
  String get listFilter_heardRecently => 'Nedavno slišan';

  @override
  String get listFilter_az => 'A do Z';

  @override
  String get listFilter_filters => 'Filtri';

  @override
  String get listFilter_all => 'Vse';

  @override
  String get listFilter_favorites => 'Priljubljene';

  @override
  String get listFilter_addToFavorites => 'Dodaj v priljubljene';

  @override
  String get listFilter_removeFromFavorites => 'Odstrani iz priljubljenih';

  @override
  String get listFilter_users => 'Uporabniki';

  @override
  String get listFilter_repeaters => 'Ponovitve';

  @override
  String get listFilter_roomServers => 'Smeti za prostore';

  @override
  String get listFilter_unreadOnly => 'Nezbrani samo';

  @override
  String get listFilter_newGroup => 'Nova skupina';

  @override
  String get pathTrace_you => 'Ti';

  @override
  String get pathTrace_failed => 'Sledenje poti ni uspelo.';

  @override
  String get pathTrace_notAvailable => 'Potni sled ni na voljo.';

  @override
  String get pathTrace_refreshTooltip => 'Osveži Path Trace.';

  @override
  String get pathTrace_someHopsNoLocation =>
      'Enemu ali več skokom manjka lokacija!';

  @override
  String get pathTrace_clearTooltip => 'Počisti pot';

  @override
  String get losSelectStartEnd => 'Izberite začetno in končno vozlišče za LOS.';

  @override
  String losRunFailed(String error) {
    return 'Preverjanje vidnega polja ni uspelo: $error';
  }

  @override
  String get losClearAllPoints => 'Počisti vse točke';

  @override
  String get losRunToViewElevationProfile =>
      'Zaženite LOS za ogled višinskega profila';

  @override
  String get losMenuTitle => 'LOS meni';

  @override
  String get losMenuSubtitle =>
      'Tapnite vozlišča ali dolgo pritisnite na zemljevid za točke po meri';

  @override
  String get losShowDisplayNodes => 'Pokaži prikazna vozlišča';

  @override
  String get losCustomPoints => 'Točke po meri';

  @override
  String losCustomPointLabel(int index) {
    return 'Po meri $index';
  }

  @override
  String get losPointA => 'Točka A';

  @override
  String get losPointB => 'Točka B';

  @override
  String losAntennaA(String value, String unit) {
    return 'Antena A: $value $unit';
  }

  @override
  String losAntennaB(String value, String unit) {
    return 'Antena B: $value $unit';
  }

  @override
  String get losRun => 'Zaženi LOS';

  @override
  String get losNoElevationData => 'Ni podatkov o višini';

  @override
  String losProfileClear(
    String distance,
    String distanceUnit,
    String clearance,
    String heightUnit,
  ) {
    return '$distance $distanceUnit, čisti LOS, najmanjša razdalja $clearance $heightUnit';
  }

  @override
  String losProfileBlocked(
    String distance,
    String distanceUnit,
    String obstruction,
    String heightUnit,
  ) {
    return '$distance $distanceUnit, blokiral $obstruction $heightUnit';
  }

  @override
  String get losStatusChecking => 'LOS: preverjam ...';

  @override
  String get losStatusNoData => 'LOS: ni podatkov';

  @override
  String losStatusSummary(int clear, int total, int blocked, int unknown) {
    return 'LOS: $clear/$total jasno, $blocked blokirano, $unknown neznano';
  }

  @override
  String get losErrorElevationUnavailable =>
      'Podatki o nadmorski višini niso na voljo za enega ali več vzorcev.';

  @override
  String get losErrorInvalidInput =>
      'Neveljavni podatki o točkah/višini za izračun LOS.';

  @override
  String get losRenameCustomPoint => 'Preimenujte točko po meri';

  @override
  String get losPointName => 'Ime točke';

  @override
  String get losShowPanelTooltip => 'Pokaži ploščo LOS';

  @override
  String get losHidePanelTooltip => 'Skrij ploščo LOS';

  @override
  String get losElevationAttribution =>
      'Podatki o višini: Open-Meteo (CC BY 4.0)';

  @override
  String get losLegendRadioHorizon => 'Radijski horizont';

  @override
  String get losLegendLosBeam => 'Linija vidnosti';

  @override
  String get losLegendTerrain => 'Teren';

  @override
  String get losBlockedSpotsTitle => 'Zasedena parkirišča';

  @override
  String get losBlockedSpotsHint =>
      'Dotaknite blokirano točko, da jo označite na zemljeplati.';

  @override
  String losBlockedSpotChip(
    String distance,
    String distanceUnit,
    String obstruction,
    String heightUnit,
  ) {
    return '$distance $distanceUnit • $obstruction $heightUnit';
  }

  @override
  String get losSelectedObstructionTitle => 'Izbrano ovire';

  @override
  String losSelectedObstructionDetails(
    String obstruction,
    String heightUnit,
    String distanceFromA,
    String distanceUnit,
    String distanceFromB,
  ) {
    return 'Blocked by $obstruction $heightUnit, $distanceFromA from A and $distanceFromB from B ($distanceUnit).';
  }

  @override
  String get losFrequencyLabel => 'Frekvenca';

  @override
  String get losFrequencyInfoTooltip => 'Prikaži podrobnosti izračuna';

  @override
  String get losFrequencyDialogTitle => 'Izračun radijskega horizonta';

  @override
  String losFrequencyDialogDescription(
    double baselineK,
    double baselineFreq,
    double frequencyMHz,
    double kFactor,
  ) {
    return 'Začenši od k=$baselineK pri $baselineFreq MHz, izračun prilagodi k-faktor za trenutni pas $frequencyMHz MHz, ki določa ukrivljeno zgornjo mejo radijskega horizonta.';
  }

  @override
  String get contacts_pathTrace => 'Sledenje poti';

  @override
  String get contacts_ping => 'Pingati';

  @override
  String get contacts_repeaterPathTrace => 'Sledi poti do ponavljalnika';

  @override
  String get contacts_repeaterPing => 'Pinguj ponavljalnik';

  @override
  String get contacts_roomPathTrace => 'Sledenje poti do strežnika sobe';

  @override
  String get contacts_roomPing => 'Ping strežnik sobe';

  @override
  String get contacts_chatTraceRoute => 'Slediti poti žarkov';

  @override
  String contacts_pathTraceTo(String name) {
    return 'Trace route to $name';
  }

  @override
  String get contacts_clipboardEmpty => 'Odložišče je prazno.';

  @override
  String get contacts_invalidAdvertFormat => 'Neveljavni kontaktne podatke';

  @override
  String get contacts_contactImported => 'Kontakt je bil uvožen.';

  @override
  String get contacts_contactImportFailed => 'Kontakt ni bil uspešno uvožen.';

  @override
  String get discoveredContacts_export => 'Izvozi odkrite stike';

  @override
  String get discoveredContacts_import => 'Uvozi odkrite stike';

  @override
  String discoveredContacts_exported(String path) {
    return 'Odkriti stiki so izvoženi v $path.';
  }

  @override
  String discoveredContacts_exportFailed(String error) {
    return 'Izvoz odkritih stikov ni uspel: $error';
  }

  @override
  String discoveredContacts_imported(int count) {
    return 'Uvoženih je bilo $count odkritih stikov.';
  }

  @override
  String get discoveredContacts_importNoContacts =>
      'V uvozni datoteki ni bilo najdenih stikov.';

  @override
  String discoveredContacts_importSummary(
    int imported,
    int skipped,
    int invalid,
  ) {
    return 'Uvoženo: $imported, preskočeno (že znani): $skipped, neberljivi vnosi: $invalid.';
  }

  @override
  String get discoveredContacts_importInvalidFile =>
      'Datoteka ni izvoz odkritih stikov.';

  @override
  String discoveredContacts_importTooLarge(int maxMb) {
    return 'Uvozna datoteka je prevelika (največ $maxMb MB).';
  }

  @override
  String discoveredContacts_importFailed(String error) {
    return 'Uvoz odkritih stikov ni uspel: $error';
  }

  @override
  String get contacts_zeroHopAdvert => 'Oglas brez posrednikov';

  @override
  String get contacts_floodAdvert => 'Flood oglas';

  @override
  String get contacts_copyAdvertToClipboard => 'Kopiraj oglas v odložišče';

  @override
  String get contacts_addContactFromClipboard => 'Dodaj stik iz odložišča';

  @override
  String get contacts_scanQrCode => 'Skeniraj QR kodo';

  @override
  String get contacts_scanQrInstructions =>
      'Usmerite kamero na QR kodo stika MeshCore';

  @override
  String get contacts_qrFromGallery => 'Skeniraj QR kodo iz galerije';

  @override
  String get contacts_noQrCodeFound =>
      'V izbrani sliki ni mogoče najti kode QR.';

  @override
  String get contacts_qrGalleryFailed => 'Galerije ni bilo mogoče odpreti.';

  @override
  String get contacts_ShareContact => 'Kopiraj stik v Odložišče';

  @override
  String get contacts_ShareContactZeroHop => 'Deliti kontakt prek oglasa';

  @override
  String get contacts_zeroHopContactAdvertSent => 'Poslano po oglasu.';

  @override
  String get contacts_zeroHopContactAdvertFailed =>
      'Pošiljanje kontakta ni uspelo.';

  @override
  String get contacts_contactAdvertCopied =>
      'Oglas je bil kopiran v odložišče.';

  @override
  String get contacts_contactAdvertCopyFailed =>
      'Kopiranje oglasa v odložišče je spodletelo.';

  @override
  String get notification_activityTitle => 'Aktivnost MeshCore';

  @override
  String notification_messagesCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'sporočil',
      few: 'sporočila',
      two: 'sporočili',
      one: 'sporočilo',
    );
    return '$count $_temp0';
  }

  @override
  String notification_channelMessagesCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'sporočil kanala',
      few: 'sporočila kanala',
      two: 'sporočili kanala',
      one: 'sporočilo kanala',
    );
    return '$count $_temp0';
  }

  @override
  String notification_newNodesCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'novih vozlišč',
      few: 'nova vozlišča',
      two: 'novi vozlišči',
      one: 'novo vozlišče',
    );
    return '$count $_temp0';
  }

  @override
  String notification_newTypeDiscovered(String contactType) {
    return 'Odkrito novo $contactType';
  }

  @override
  String get notification_receivedNewMessage => 'Prejeto novo sporočilo';

  @override
  String get notification_actionReply => 'Odgovori';

  @override
  String get notification_actionMarkRead => 'Označi kot prebrano';

  @override
  String get notification_actionMuteChannel => 'Utišaj kanal';

  @override
  String get notification_replyHint => 'Sporočilo';

  @override
  String get notification_you => 'Vi';

  @override
  String get notification_replyFailedTitle => 'Odgovor ni bil poslan';

  @override
  String get notification_replyNotConnected =>
      'Ni povezave z radiom. Ponovno se povežite v MeshCore Open in ponovno pošite odgovor.';

  @override
  String get notification_replyTooLong =>
      'Vaš odgovor je predolg za pošiljanje iz obvestila. Pošite ga namesto tega iz MeshCore Open.';

  @override
  String get notification_replyUnavailable =>
      'Ta pogovor ni več na povezanem radiu.';

  @override
  String get notification_replySendFailed =>
      'Vaš odgovor morda ni bil poslan. Preverite v MeshCore Open in poskusite znova.';

  @override
  String get notification_replyAppNotRunning =>
      'MeshCore Open ne teče. Odprite ga in ponovno pošite odgovor.';

  @override
  String get settings_gpxExportRepeaters =>
      'Izvoz ponoviteljev / strežnika sobe v GPX';

  @override
  String get settings_gpxExportRepeatersSubtitle =>
      'Izvozi ponovljene oddajnike / strežnik sobe z lokacijo v datoteko GPX.';

  @override
  String get settings_gpxExportContacts => 'Izvoz spremljevalcev v GPX';

  @override
  String get settings_gpxExportContactsSubtitle =>
      'Izvozi spremljevalce z lokacijo v datoteko GPX.';

  @override
  String get settings_gpxExportAll => 'Izvozi vse kontakte v GPX';

  @override
  String get settings_gpxExportAllSubtitle =>
      'Izvozi vse kontakte z lokacijo v datoteko GPX.';

  @override
  String get settings_gpxExportSuccess => 'Uspešno izvoz GPX datoteke.';

  @override
  String get settings_gpxExportNoContacts => 'Ni stikov za izvoz.';

  @override
  String get settings_gpxExportNotAvailable =>
      'Ni podprto na vašem napravi/operacijskem sistemu';

  @override
  String get settings_gpxExportError => 'Pri izvozu je prišlo do napake.';

  @override
  String get settings_gpxExportRepeatersRoom =>
      'Lokacije ponovljivca in strežnika sobe';

  @override
  String get settings_gpxExportChat => 'Lokacije spremljevalcev';

  @override
  String get settings_gpxExportAllContacts => 'Lokacije vseh stikov';

  @override
  String get settings_gpxExportShareText =>
      'Podatki kart izvoženi iz meshcore-open';

  @override
  String get settings_gpxExportShareSubject =>
      'meshcore-open izvoz podatkov GPX karte';

  @override
  String get snrIndicator_nearByRepeaters => 'Bližnji ponovitelji';

  @override
  String get snrIndicator_lastSeen => 'Zadnjič videno';

  @override
  String get snrIndicator_nearByRepeatersDescription =>
      'Ponovitelji, ki jih je vaše radio slišalo neposredno, najprej nazadnje slišani.';

  @override
  String get contactsSettings_title => 'Nastavitve stikov';

  @override
  String get contactsSettings_autoAddTitle => 'Avtomatsko odkrivanje';

  @override
  String get contactsSettings_otherTitle => 'Druge nastavitve v zvezi s stiki';

  @override
  String get contactsSettings_autoAddUsersTitle =>
      'Avtomatsko dodaj uporabnike';

  @override
  String get contactsSettings_autoAddUsersSubtitle =>
      'Dovoli spremljevalcu, da samodejno doda odkrite uporabnike.';

  @override
  String get contactsSettings_autoAddRepeatersTitle =>
      'Avtomatsko dodaj ponovitelje';

  @override
  String get contactsSettings_autoAddRepeatersSubtitle =>
      'Dovoli spremljevalcu, da samodejno doda odkrite ponovitelje.';

  @override
  String get contactsSettings_autoAddRoomServersTitle =>
      'Avtomatsko dodaj strežnike sob';

  @override
  String get contactsSettings_autoAddRoomServersSubtitle =>
      'Dovoli spremljevalcu, da samodejno doda odkrite strežnike sob.';

  @override
  String get contactsSettings_autoAddSensorsTitle =>
      'Avtomatsko dodaj senzorje';

  @override
  String get contactsSettings_autoAddSensorsSubtitle =>
      'Dovoli spremljevalcu, da samodejno doda odkrite senzorje.';

  @override
  String get contactsSettings_overwriteOldestTitle => 'Prepiši najstarejše';

  @override
  String get contactsSettings_overwriteOldestSubtitle =>
      'Ko je seznam stikov poln, bo najstarejši nestarševski stik zamenjan.';

  @override
  String get contactsSettings_evictDiscoveredContactsTitle =>
      'Odstrani odkrite stike';

  @override
  String contactsSettings_evictDiscoveredContactsSubtitle(int limit) {
    return 'Ko je ta možnost vklopljena, aplikacija odstrani najstarejše odkrite stike, ko seznam odkritih stikov doseže omejitev $limit vnosov.';
  }

  @override
  String get discoveredContacts_Title => 'Odkriti stiki';

  @override
  String get discoveredContacts_noMatching => 'Ni ujemajočih stikov';

  @override
  String get discoveredContacts_searchHint => 'Najdeni stiki po iskanju';

  @override
  String get discoveredContacts_contactAdded => 'Kontakt dodan';

  @override
  String get discoveredContacts_addContact => 'Dodaj stik';

  @override
  String get discoveredContacts_copyContact => 'Kopiraj stik v odložišče';

  @override
  String get discoveredContacts_deleteContact => 'Izbriši stik';

  @override
  String get discoveredContacts_deleteContactAll =>
      'Izbriši vse odkrite kontakte';

  @override
  String get discoveredContacts_deleteContactAllContent =>
      'Ste prepričani, da želite izbrisati vse odkrite kontakte?';

  @override
  String get discoveredContacts_scan => 'Poišči vozlišča v bližini';

  @override
  String get discoveredContacts_scanTitle => 'Vozlišča v bližini';

  @override
  String get discoveredContacts_scanExplanation =>
      'Vozlišča v neposrednem dosegu radia prosi, naj se predstavijo. Odgovorijo ponovitelji in senzorji. Strežniki sob in spremljevalci običajno ne.';

  @override
  String get discoveredContacts_scanning => 'Iskanje …';

  @override
  String discoveredContacts_scanFound(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Najdenih $count vozlišč',
      few: 'Najdena $count vozlišča',
      two: 'Najdeni $count vozlišči',
      one: 'Najdeno 1 vozlišče',
    );
    return '$_temp0';
  }

  @override
  String get discoveredContacts_scanNoResults =>
      'Nobeno vozlišče ni odgovorilo. Ponovitelji omejujejo pogostost odgovorov, zato poskusite znova čez minuto.';

  @override
  String get discoveredContacts_scanAgain => 'Išči znova';

  @override
  String get discoveredContacts_scanFailed =>
      'Zahtevka za iskanje ni bilo mogoče poslati.';

  @override
  String discoveredContacts_scanSignal(String snr, String remoteSnr) {
    return 'Signal $snr dB · slišali so nas pri $remoteSnr dB';
  }

  @override
  String get discoveredContacts_scanInContacts => 'Že med stiki';

  @override
  String get discoveredContacts_scanNameLater =>
      'Ime se prikaže po naslednjem oglasu';

  @override
  String get chat_sendCooldown =>
      'Prosimo, počakajte trenutek, preden pošljete ponovno.';

  @override
  String get appSettings_jumpToOldestUnread =>
      'Pritisnite za najstarejše nepročitano sporočilo';

  @override
  String get appSettings_jumpToOldestUnreadSubtitle =>
      'Ko odpirate klepet z neprebranimi sporočili, se premaknite na prvo neprebrano sporočilo, namesto najnovejšega.';

  @override
  String get appSettings_languageHu => 'Madžarski';

  @override
  String get appSettings_languageJa => 'Japonski';

  @override
  String get appSettings_languageKo => 'Korejski';

  @override
  String get radioStats_tooltip => 'Statistike za radio in mrežo';

  @override
  String get radioStats_screenTitle => 'Radijske statistike';

  @override
  String get radioStats_sectionSignal => 'Signal';

  @override
  String get radioStats_sectionAirtime => 'Čas v etru';

  @override
  String get radioStats_notConnected =>
      'Povežite se z napravo, da si ogledate statistiko o radiju.';

  @override
  String get radioStats_firmwareTooOld =>
      'Statistika za radio zahteva združljivo programsko opremo v8 ali kasnejše.';

  @override
  String get radioStats_waiting => 'Čakam na podatke…';

  @override
  String radioStats_noiseFloor(int noiseDbm) {
    return 'Število šuma: $noiseDbm dBm';
  }

  @override
  String radioStats_lastRssi(int rssiDbm) {
    return 'Najkasnejše vrednost RSSI: $rssiDbm dBm';
  }

  @override
  String radioStats_lastSnr(String snr) {
    return 'Najkasnejše vrednost SNR: $snr dB';
  }

  @override
  String radioStats_txAir(int seconds) {
    return 'Čas na TX (skupno): $seconds s';
  }

  @override
  String radioStats_rxAir(int seconds) {
    return 'Čas, namenjen RX-ju (skupno): $seconds s';
  }

  @override
  String get radioStats_chartCaption =>
      'Ravnovredna raven šuma (dBm) za nedavne vzorce.';

  @override
  String radioStats_stripNoise(int noiseDbm) {
    return 'Število šuma: $noiseDbm dBm';
  }

  @override
  String get radioStats_stripWaiting => 'Prejemanje statistike o radiju…';

  @override
  String get radioStats_settingsTile => 'Radijske statistike';

  @override
  String get radioStats_settingsSubtitle =>
      'Število šumov, RSSI, SNR in čas, ki ga je napolnila oprema';

  @override
  String get translation_title => 'Prevod';

  @override
  String get imageMessages_enableTitle => 'Pozivni izkričile slike';

  @override
  String get imageMessages_enableSubtitle =>
      'Prešli vzorce pre mrežo. Potrebno je jednokratno stworiti model vzorca.';

  @override
  String get imageMessages_modelSectionTitle => 'Obrazni model';

  @override
  String get imageMessages_downloadModel => 'Storba';

  @override
  String get imageMessages_cancelDownload => 'Odločite';

  @override
  String get imageMessages_removeModel => 'Ubrani model';

  @override
  String get imageMessages_modelReady => 'Gotov';

  @override
  String get imageMessages_modelNotPublished =>
      'Jo še niso izdana — ta izdelka te ne može prebaviti.';

  @override
  String get imageMessages_downloadFailed =>
      'Obrazni model ne može biti preuzet.';

  @override
  String get imageMessages_autoProcessTitle => 'Avtomatizirane slike';

  @override
  String get imageMessages_autoProcessSubtitle =>
      'Katero je oblikovanje svega oblikov, ko se pošteva. Za drugo okolo časa se koristi ok. 2 GB pamične prostore; odločite se za oblikovanje s tukom.';

  @override
  String get translation_enableTitle => 'Omogočite prevod';

  @override
  String get translation_enableSubtitle =>
      'Prevedite vstopne sporočila in omogočite predhodno prevajanje.';

  @override
  String get translation_composerTitle => 'Preprištejte, preden pošljete';

  @override
  String get translation_composerSubtitle =>
      'Ureja privzeto stanje ikone za prevod, ki jo uporablja avtor.';

  @override
  String get translation_autoIncomingTitle => 'Samodejno prevajaj sporočila';

  @override
  String get translation_autoIncomingSubtitle =>
      'Samodejno prevaja sporočila za obvestila ter za klepete ali kanale.';

  @override
  String get translation_translateMessage => 'Prevedi sporočilo';

  @override
  String get translation_targetLanguage => 'Ciljna jezika';

  @override
  String get translation_useAppLanguage => 'Uporabite jezik aplikacije';

  @override
  String get translation_downloadedModelLabel => 'Naložen model';

  @override
  String get translation_presetModelLabel =>
      'Prednastavljeni model Hugging Face';

  @override
  String get translation_manualUrlLabel => 'URL za ročni model';

  @override
  String get translation_downloadModel => 'Prenesite model';

  @override
  String get translation_downloading => 'Izvajanje...';

  @override
  String get translation_working => 'Delo...';

  @override
  String get translation_stop => 'Prekliji';

  @override
  String get translation_mergingChunks =>
      'Sklapljanje prenesenih delov v končni datoteko...';

  @override
  String get translation_downloadedModels => 'Naloženi modeli';

  @override
  String get translation_deleteModel => 'Izbrisati model';

  @override
  String get translation_modelDownloaded =>
      'Model za prevajanje je bil naložen.';

  @override
  String get translation_downloadStopped => 'Prenos je bil prekinjen.';

  @override
  String translation_downloadFailed(String error) {
    return 'Izgovoritev ni bila uspešna: $error';
  }

  @override
  String get translation_enterUrlFirst => 'Najprej vnesite URL model.';

  @override
  String get scanner_linuxPairingShowPin => 'Prikaži PIN';

  @override
  String get scanner_linuxPairingHidePin => 'Skrij PIN';

  @override
  String get scanner_linuxPairingPinTitle => 'Bluetooth PIN za seznanjanje';

  @override
  String scanner_linuxPairingPinPrompt(String deviceName) {
    return 'Vnesite PIN za $deviceName (pustite prazno, če ga ni).';
  }

  @override
  String get translation_messageTranslation => 'Prevod sporočila';

  @override
  String get translation_translateBeforeSending =>
      'Preprištejte, preden pošljete';

  @override
  String get translation_composerEnabledHint =>
      'Vsebina sporočil bo prevedena, preden jih pošljemo.';

  @override
  String get translation_composerDisabledHint =>
      'Pošljite sporočila v originalnem tipkanem jeziku.';

  @override
  String translation_translateTo(String language) {
    return 'Prevesti v $language';
  }

  @override
  String get translation_translationOptions => 'Možnosti prevoda';

  @override
  String get translation_systemLanguage => 'Jezik sistema';

  @override
  String get background_serviceTitle => 'MeshCore running';

  @override
  String get background_serviceText => 'Keeping BLE connected';

  @override
  String appSettings_translationModelDeleted(String name) {
    return 'Deleted $name';
  }

  @override
  String appSettings_translationModelDeleteFailed(String error) {
    return 'Failed to delete: $error';
  }

  @override
  String channels_channelUpdateFailed(String error) {
    return 'Failed to update channel: $error';
  }

  @override
  String get contact_typeChat => 'Chat';

  @override
  String get contact_typeRepeater => 'Repeater';

  @override
  String get contact_typeRoom => 'Room';

  @override
  String get contact_typeSensor => 'Sensor';

  @override
  String get contact_typeUnknown => 'Unknown';

  @override
  String get map_zoomIn => 'Povečaj';

  @override
  String get map_zoomOut => 'Povečajte pogled';

  @override
  String get map_centerMap => 'Krajšarska karta';

  @override
  String get chrome_bluetoothRequiresChromium =>
      'Web Bluetooth zahteva brskalnik Chromium.';

  @override
  String channels_communityShortId(String id) {
    return 'ID: $id...';
  }

  @override
  String get pathTrace_legendGpsConfirmed => 'GPS potrdilo';

  @override
  String get pathTrace_legendInferred => 'Izpeljana lokacija';

  @override
  String get pathMap_viewSingle => 'Posamično';

  @override
  String get pathMap_viewCombined => 'Skupno';

  @override
  String get pathMap_play => 'Predvajaj';

  @override
  String get pathMap_pause => 'Premor';

  @override
  String get pathMap_replay => 'Ponovitev';

  @override
  String get pathMap_stepBack => 'Prejšnji skok';

  @override
  String get pathMap_stepForward => 'Naslednji skok';

  @override
  String get pathMap_animationOn => 'Prikaži animacijo paketa';

  @override
  String get pathMap_animationOff => 'Skrij animacijo paketa';

  @override
  String pathMap_hopOf(int current, int total) {
    return 'Skok $current od $total';
  }

  @override
  String pathMap_observedPaths(int count) {
    return 'Opazovane poti: $count';
  }

  @override
  String get pathMap_primary => 'Primarna';

  @override
  String pathMap_alternate(int index) {
    return 'Alternativa $index';
  }

  @override
  String pathMap_hopCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count skokov',
      few: '$count skoki',
      two: '2 skoka',
      one: '1 skok',
    );
    return '$_temp0';
  }

  @override
  String pathMap_gpsCount(int confirmed, int total) {
    return '$confirmed/$total GPS';
  }

  @override
  String get pathMap_legendShared => 'Deljen segment';

  @override
  String get pathMap_legendEstimated => 'Ocenjen segment';

  @override
  String pathMap_sharedNodeCount(int count) {
    return 'Uporablja $count poti';
  }

  @override
  String pathMap_partialAnimation(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count skokov nima lokacije — prikazana pot je delna',
      few: '$count skoki nimajo lokacije — prikazana pot je delna',
      two: '2 skoka nimata lokacije — prikazana pot je delna',
      one: '1 skok nima lokacije — prikazana pot je delna',
    );
    return '$_temp0';
  }

  @override
  String get pathMap_showAllPaths => 'Pokaži vse';

  @override
  String get pathMap_hidePath => 'Skrij pot';

  @override
  String get pathMap_showPath => 'Pokaži pot';

  @override
  String get pathMap_collapsePanel => 'Strni ploščo';

  @override
  String get pathMap_expandPanel => 'Razširi ploščo';

  @override
  String get pathMap_noLocation => 'Brez lokacije';

  @override
  String get pathMap_followPacket => 'Zakleni pogled na paket';

  @override
  String get pathMap_unfollowPacket => 'Odkleni pogled od paketa';

  @override
  String get imageSend_title => 'Sločaji slik';

  @override
  String get imageSend_cropNote =>
      'Zadovoljno izmenjeno na 512 × 512 · vzorovni odnos ne ohranjen';

  @override
  String imageSend_lossyNote(int bytes) {
    return 'Stisnjeno na približno $bytes bajtov. Model prejemnika sliko rekonstruira, zato bodo podrobnosti različne.';
  }

  @override
  String get imageSend_viewOriginal => 'Izvirnik';

  @override
  String get imageSend_viewReconstruction => 'Kaj vidijo prejemniki';

  @override
  String get imageSend_reconstructionUnavailable =>
      'Ta naprava ne more prikazati predogleda rekonstrukcije.';

  @override
  String get imageSend_modelNotDownloaded =>
      'Obrazni model še ni prenesen. Prenesite ga v Nastavitvah, da boste lahko pošiljali slike.';

  @override
  String get imageSend_originalSize =>
      'Original text:\n\nThe early bird catches the worm.\n\nTranslation:\n\nPojdi prvi, zlati v kroku.';

  @override
  String get imageSend_onAirSize => 'Na vodi';

  @override
  String get imageSend_quality => 'Kakovost';

  @override
  String get imageSend_qualityStandard => 'Standard';

  @override
  String get imageSend_qualityHigh => 'Vysoko';

  @override
  String get imageSend_packetsLabel => 'Pakete';

  @override
  String get imageSend_airtimeLabel => 'Čas v eteru';

  @override
  String get imageSend_sizeLabel => 'Napravo';

  @override
  String imageSend_packetsCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'paketov',
      one: 'paket',
    );
    return '$count $_temp0';
  }

  @override
  String imageSend_range(String min, String max) {
    return '$min–$max';
  }

  @override
  String get imageSend_unknownValue => '—';

  @override
  String get imageSend_radioUnknownTitle => 'Naslušniki radio neznane';

  @override
  String get imageSend_radioUnknownBody =>
      'Poučajte se na stroj, da se lahko izračunuje čas v prikazu.';

  @override
  String get imageSend_longSendTitle => 'Dluga preposlana';

  @override
  String imageSend_longSendBody(String duration) {
    return 'Ovo bo ohranilo kanal prihodno za obliko $duration.';
  }

  @override
  String get imageSend_floodNote =>
      'Flood usmerjanje: vsak ponovitelj v dosegu znova odda vsak paket, zato je kanal zaseden dlje kot to.';

  @override
  String get imageSend_parityTitle => 'Pobavni paket zdržbe';

  @override
  String get imageSend_paritySubtitle =>
      'Jedna dodatna paczka. Grupni izjasi ne izvajajo potvarnosti, pa ta izdelka omogoča preuzimanju ponovno izgleda, če je zgubjen pojedni paket.';

  @override
  String get imageSend_send => 'Posyłaj';

  @override
  String get imageSend_cancel => 'Odločite';

  @override
  String get imageSend_encodeFailed => 'Ovo slikovo ne more biti zakodirano.';

  @override
  String get imageSend_codecDownloading =>
      'Obrazni model še pospeva preborjanje.';

  @override
  String get imageSend_codecUnavailable =>
      'Poslanje slike nema na tem zelo naročnem naročnem.';

  @override
  String get imageSend_codecDisabled => 'Obrazi s pomanjkanjem so v nastavnih.';

  @override
  String get imageSend_deviceUnsupported =>
      'Taj radio ne može posredovati slike pakuete. Prepoštijo izbirni napravnik s kompanijskimi programi na čevem 13 ali novšejšim.';

  @override
  String get imageSend_directMessagesUnsupported =>
      'Obrazy se pojavijo kot skupnih podatkov, pa lahko ih poslujejo samo na kanal — ne v prilogih.';

  @override
  String get imageSend_tooLarge =>
      'Taj slik je zakodiran v viših pakotnih od športne formate, ki omogoča mrežni format.';

  @override
  String imageSend_sentConfirmation(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'paketov',
      one: 'paket',
    );
    return 'Slika poslana kot $count $_temp0.';
  }

  @override
  String imageSend_sendFailed(String error) {
    return 'Obraz ne može biti poslany: $error';
  }

  @override
  String imageSend_sendingProgress(int sent, int total) {
    return 'Prekazivanje izkaza — paket $sent od $total';
  }

  @override
  String receivedImage_senderPrefix(String prefix) {
    return 'Vrtitev $prefix';
  }

  @override
  String receivedImage_incoming(int received, int total) {
    return 'Otrteno od $received na $total poslovanih potokov';
  }

  @override
  String get receivedImage_queued => 'Čekanje, da se dekodira';

  @override
  String get receivedImage_tapToDecode => 'Kliknite, da razkrivete';

  @override
  String get receivedImage_decoding =>
      'Ostvarjanje… o prihodnosti za okolo 1 s';

  @override
  String receivedImage_incomplete(int received, int total) {
    return 'Obraz nije kompletan — $received od $total poslaničev je prishodil';
  }

  @override
  String get receivedImage_corrupt => 'Obraz ne more lahko rekonstruirati';

  @override
  String get receivedImage_decoderMissing =>
      'Otrgena slika — dekodirana slika je izključena';

  @override
  String get receivedImage_evicted => 'Obraz ni več niso zakajiren';

  @override
  String get receivedImage_retry => 'Pokušajte znova';

  @override
  String get receivedImage_decodeAgain => 'Dekodiraj ponovno';

  @override
  String get receivedImage_openSettings => 'Nastavite';

  @override
  String get receivedImage_tapToProcess => 'Kliknij za obravnavanje';

  @override
  String get receivedImage_save => 'Shrani sliko';

  @override
  String receivedImage_shareCaption(int bytes) {
    return 'Z umetno inteligenco rekonstruirano iz $bytes bajtov; drobni detajli so generirani, ne poslani.';
  }

  @override
  String get receivedImage_packetInfo => 'Podatki o paketu';

  @override
  String get receivedImage_parityRecovered =>
      'En paket je bil rekonstruiran iz obnovitvenega paketa.';

  @override
  String receivedImage_decodeTime(int ms) {
    return 'Rekonstruirano v $ms ms';
  }

  @override
  String get receivedImage_saveFailed => 'Slike ni bilo mogoče shraniti';

  @override
  String receivedImage_awaiting(int bytes, int packets) {
    String _temp0 = intl.Intl.pluralLogic(
      packets,
      locale: localeName,
      other: 'paketov',
      one: 'paket',
    );
    return '$bytes bajtov · $packets $_temp0';
  }

  @override
  String imageSend_secondsValue(String seconds) {
    return '$seconds s';
  }

  @override
  String imageSend_minutesSecondsValue(String minutes, String seconds) {
    return '$minutes m $seconds s';
  }

  @override
  String chat_longMessageRetryNote(int count) {
    return 'Nad 158 bajtov: poslano največ $count-krat';
  }

  @override
  String get reviewMode_dialogTitle => 'Vstop v način pregleda?';

  @override
  String get reviewMode_dialogBody =>
      'Način pregleda se poveže s simuliranim radiem z vzorčnimi stiki, kanali in sporočili. Pravi radio ni potreben.';

  @override
  String get reviewMode_confirm => 'Vstopi';

  @override
  String get reviewMode_cancel => 'Prekliči';

  @override
  String get reviewMode_banner => 'Način pregleda — simulirani podatki';

  @override
  String get reviewMode_sendTest => 'Pošlji testno sporočilo';

  @override
  String get reviewMode_testSent => 'Kmalu bo prispelo testno sporočilo.';

  @override
  String get reviewMode_exit => 'Izhod';

  @override
  String reviewMode_connectFailed(String error) {
    return 'Načina pregleda ni bilo mogoče zagnati: $error';
  }

  @override
  String get channels_waitForSync =>
      'Kanali se še nalagajo iz radia. Poskusite znova, ko se sinhronizacija konča.';

  @override
  String channels_nameTooLong(int maxBytes) {
    return 'Ime je predolgo (največ $maxBytes bajtov).';
  }

  @override
  String repeater_valueRequired(String field) {
    return '$field: vnesite vrednost';
  }

  @override
  String get losMapDetailTooltip => 'Podrobnost zemljevida';

  @override
  String get losUnitsTooltip => 'Enote';

  @override
  String get losDistance => 'Razdalja';

  @override
  String get losClearance => 'Prosti prostor';

  @override
  String get losBlockedBy => 'Blokirano';

  @override
  String get losObstruction => 'Ovira';

  @override
  String losDistanceFromA(String distance) {
    return '$distance od A';
  }

  @override
  String get losWorstBadge => 'NAJSLABŠA';

  @override
  String losBlockedAmount(String amount) {
    return 'Blokirano $amount';
  }

  @override
  String get losFromA => 'Od A';

  @override
  String get losFromB => 'Od B';

  @override
  String get losElevation => 'Višina';

  @override
  String get losCenterOnMap => 'Središči na zemljevidu';

  @override
  String get losStatusClear => 'Prosto';

  @override
  String get losStatusMarginal => 'Mejno';

  @override
  String get losStatusBlocked => 'Blokirano';

  @override
  String get losStatusCheckingShort => 'Preverjanje';

  @override
  String get losStatusNoResult => 'Ni rezultata';

  @override
  String get losSelectedPill => 'Izbrano';

  @override
  String get gif_tapToLoad => 'Tapnite za nalaganje GIF-a';

  @override
  String get gif_loadFailedRetry =>
      'GIF-a ni mogoče naložiti\nTapnite za ponovni poskus';

  @override
  String get qr_cameraPermissionDenied =>
      'Dovoljenje za kamero zavrnjeno.\nOmogočite dostop do kamere v nastavitvah.';

  @override
  String get qr_cameraUnsupported => 'Kamera na tej napravi ni podprta.';

  @override
  String qr_cameraStartFailed(String details) {
    return 'Kamere ni bilo mogoče zagnati.\n$details';
  }

  @override
  String imageMessages_downloadFailedWithError(String error) {
    return 'Slikovnega modela ni bilo mogoče prenesti: $error';
  }

  @override
  String get map_nodeId => 'ID';

  @override
  String get map_markerHideHint =>
      'Skrij: skrito, dokler ne zapustite zemljevida.';

  @override
  String get map_markerRemoveHint =>
      'Odstrani: ostane skrito, dokler ga ne obnovite v meniju filtra.';

  @override
  String get map_markerRemoved => 'Oznaka odstranjena';

  @override
  String get map_restoreRemovedMarkers => 'Obnovi odstranjene oznake';

  @override
  String map_restoreRemovedMarkersSubtitle(int count) {
    return 'Odstranjenih: $count';
  }

  @override
  String map_markersRestored(int count) {
    return 'Obnovljenih oznak: $count';
  }

  @override
  String get map_setLocationConfirmTitle => 'Nastavim kot vašo lokacijo?';

  @override
  String map_setLocationConfirmBody(String lat, String lon) {
    return 'Vaše vozlišče bo oglaševalo ta položaj:\n$lat, $lon';
  }

  @override
  String get map_setLocationAction => 'Nastavi lokacijo';

  @override
  String get map_locationSetSuccess => 'Lokacija vozlišča posodobljena';

  @override
  String get map_locationSetFailed =>
      'Naprava ni potrdila nove lokacije. Poskusite znova.';

  @override
  String map_poiClusterTitle(int count) {
    return 'Oznak tukaj: $count';
  }

  @override
  String map_poiClusterSemantics(int count) {
    return 'Deljenih oznak: $count. Tapnite za prikaz seznama.';
  }

  @override
  String map_youWithMarkers(int count) {
    return 'Vi in oznak: $count';
  }

  @override
  String map_sharedMarkerSemantics(String label) {
    return 'Deljena oznaka: $label';
  }

  @override
  String map_nodeMarkerSemantics(String name, String type, String status) {
    return '$name, $type, $status';
  }

  @override
  String mapCache_zoomLevel(int zoom) {
    return 'Povečava $zoom';
  }

  @override
  String mapCache_sizeBytes(String size) {
    return '$size B';
  }

  @override
  String mapCache_sizeKilobytes(String size) {
    return '$size KB';
  }

  @override
  String mapCache_sizeMegabytes(String size) {
    return '$size MB';
  }

  @override
  String mapCache_sizeGigabytes(String size) {
    return '$size GB';
  }

  @override
  String mapCache_downloadCancelled(int count) {
    return 'Prenos preklican. V predpomnilniku je $count ploščic.';
  }

  @override
  String get mapCache_tooManyTilesTitle => 'Območje je preveliko';

  @override
  String mapCache_tooManyTiles(int count, int max) {
    return 'To območje potrebuje $count ploščic, kar presega omejitev $max. Izberite manjše območje ali zmanjšajte največjo povečavo.';
  }

  @override
  String get chat_clearChatConfirm =>
      'S te naprave bodo izbrisana vsa sporočila v tem pogovoru. Dejanja ni mogoče razveljaviti.';

  @override
  String get channels_clearChatConfirm =>
      'S te naprave bodo izbrisana vsa sporočila v tem kanalu, vključno s prejetimi slikami. Dejanja ni mogoče razveljaviti.';

  @override
  String get channels_timeNow => 'zdaj';

  @override
  String channels_timeMinutes(int minutes) {
    return '$minutes min';
  }

  @override
  String channels_timeHours(int hours) {
    return '$hours h';
  }

  @override
  String channels_timeDays(int days) {
    return '$days d';
  }

  @override
  String channels_indexChip(int index) {
    return 'KAN $index';
  }

  @override
  String get reaction_unknownSender => 'Neznano';

  @override
  String get pathMap_noSelfGpsFix => 'Lokalno vozlišče nima GPS-a';

  @override
  String pathTrace_sendFailed(String error) {
    return 'Poti ni bilo mogoče poslati: $error';
  }

  @override
  String get losErrorNoInternet =>
      'Podatki o nadmorski višini zahtevajo internetno povezavo';

  @override
  String get losResultStale => 'Zastarelo: višina antene se je spremenila';

  @override
  String losSnrValue(String snr) {
    return '$snr dB';
  }

  @override
  String losFrequencyValue(String frequency) {
    return '$frequency MHz';
  }

  @override
  String losKFactorValue(String kFactor) {
    return 'k=$kFactor';
  }

  @override
  String get losEndpointA => 'A';

  @override
  String get losEndpointB => 'B';

  @override
  String get units_km => 'km';

  @override
  String get units_mi => 'mi';

  @override
  String get units_m => 'm';

  @override
  String get units_ft => 'ft';

  @override
  String get telemetry_loading => 'Nalaganje telemetrije…';

  @override
  String telemetry_axisValue(String x, String y, String z) {
    return 'X: $x, Y: $y, Z: $z';
  }

  @override
  String telemetry_colourValue(String red, String green, String blue) {
    return 'R: $red, G: $green, B: $blue';
  }

  @override
  String telemetry_altitudeValueFeet(String feet) {
    return '$feet ft';
  }

  @override
  String telemetry_distanceValueFeet(String feet) {
    return '$feet ft';
  }

  @override
  String get settings_notConnectedError =>
      'Ni povezave z radiem. Povežite se in poskusite znova.';

  @override
  String get settings_requiresConnection => 'Za to se povežite z radiem';

  @override
  String settings_txPowerInvalidRange(int min, int max) {
    return 'Neveljavna moč TX ($min do $max dBm)';
  }

  @override
  String get settings_contactSettingsSaved => 'Nastavitve stika shranjene';

  @override
  String get settings_batteryToggleHint =>
      'Tapnite za preklop med odstotki in napetostjo';

  @override
  String get settings_publicKeyCopyHint => 'Kopiraj javni ključ';

  @override
  String get settings_locationClearHelper =>
      'Obe polji pustite prazni, če želite odstraniti svojo lokacijo.';

  @override
  String get settings_locationCleared => 'Lokacija odstranjena';

  @override
  String get settings_regionFetchDiscovering => 'Iskanje bližnjih ponovitelj…';

  @override
  String settings_regionFetchProgress(int current, int total) {
    return 'Spraševanje ponovitelja $current od $total…';
  }

  @override
  String get settings_regionFetchNoRepeaters =>
      'Zaenkrat ni znanih ponovitelj. Dodajte ponovitelj kot stik ali počakajte, da se oglasi, nato poskusite znova.';

  @override
  String get settings_regionFetchNoneResponded =>
      'Noben bližnji ponovitelj ni odgovoril. Približajte se ponovitelju in poskusite znova.';

  @override
  String appSettings_sourceSummary(String label, String description) {
    return '$label - $description';
  }

  @override
  String get appSettings_routingSection => 'Usmerjanje';

  @override
  String get appSettings_imageMessagesSection => 'Sporočila s slikami';

  @override
  String get appSettings_showApiKey => 'Pokaži API ključ';

  @override
  String get appSettings_hideApiKey => 'Skrij API ključ';

  @override
  String get translation_defaultModelName => 'Model';

  @override
  String translation_downloadProgressBytes(String fileName, String current) {
    return '$fileName: $current MB';
  }

  @override
  String translation_downloadProgressTotal(
    String fileName,
    String current,
    String total,
    String percent,
  ) {
    return '$fileName: $current / $total MB ($percent%)';
  }

  @override
  String translation_downloadedModelDetails(String size, String source) {
    return '$size MB • $source';
  }

  @override
  String get repeater_radioDisconnected => 'Radio odklopljen';

  @override
  String get repeater_radioDisconnectedHint =>
      'Znova se povežite z radiem, da pošljete ukaze, osvežite ali shranite spremembe.';

  @override
  String get repeater_cliSend => 'Pošlji ukaz';

  @override
  String get repeater_cliCopyTranscript => 'Kopiraj prepis';

  @override
  String get repeater_cliShareTranscript => 'Deli prepis';

  @override
  String get repeater_cliTranscriptCopied => 'Prepis kopiran';

  @override
  String get repeater_cliClearHistoryConfirm =>
      'Počistim zgodovino ukazov? Dejanja ni mogoče razveljaviti.';

  @override
  String get repeater_cliSearchCommands => 'Išči ukaze';

  @override
  String get repeater_cliNoMatchingCommands => 'Ni ustreznih ukazov';

  @override
  String get debugLog_clearConfirm =>
      'Počistim vse vnose dnevnika? Dejanja ni mogoče razveljaviti.';

  @override
  String get repeater_unsavedChangesTitle => 'Neshranjene spremembe';

  @override
  String get repeater_unsavedChangesMessage =>
      'Imate spremembe, ki niso shranjene v ponovitelju.';

  @override
  String get repeater_discardChanges => 'Zavrzi';

  @override
  String repeater_actionSentNoReply(String action) {
    return '$action: ukaz poslan. Ponovitelj na ta ukaz ne odgovori.';
  }

  @override
  String repeater_invalidSettingValue(String setting, String value) {
    return '$setting: $value ni veljavno';
  }

  @override
  String repeater_txPowerOutOfRange(String value, int min, int max) {
    return 'Moč TX $value je izven območja ($min do $max dBm)';
  }

  @override
  String repeater_prvKeyLengthError(int length) {
    return 'Zasebni ključ mora imeti točno $length šestnajstiških znakov';
  }

  @override
  String get contacts_advertFailed => 'Oglasa ni bilo mogoče poslati';

  @override
  String get contacts_manageGroups => 'Upravljaj skupine';

  @override
  String community_shortId(String id) {
    return 'ID: $id…';
  }

  @override
  String get tcpSectionTitle => 'TCP / IP';

  @override
  String get tcpConnectedToHeader => 'Povezano z';

  @override
  String get usbChooseSerialPort => 'Izberite serijska vrata';

  @override
  String neighbors_durationSeconds(String seconds) {
    return '$seconds s';
  }

  @override
  String neighbors_durationMinutes(int minutes, String seconds) {
    return '$minutes min $seconds s';
  }

  @override
  String neighbors_durationHours(int hours, int minutes) {
    return '$hours h $minutes min';
  }

  @override
  String get networkMap_settingsSection => 'Omrežni zemljevid';

  @override
  String get networkMap_uploadTitle => 'Deli, kaj sliši moj radio';

  @override
  String get networkMap_uploadExplanation =>
      'Ko je to vklopljeno in je radio povezan, aplikacija na omrežni zemljevid MeshCore Open pošlje kratek povzetek paketov, ki jih sliši vaš radio, tako da vsi vidijo, kateri repeaterji obstajajo in kako so povezani. Pošlje vrsto, pot, število skokov, moč signala in velikost vsakega paketa ter imena in približne lokacije repeaterjev iz njihovih lastnih advertov. Nikoli ne pošlje besedila sporočil, kdo se s kom pogovarja, imen kanalov, vaših stikov ali vašega natančnega položaja: lokacije so zaokrožene na približno 2 km, aplikacija pa vsak dan dobi nov naključni ID.';

  @override
  String get networkMap_whatWeCollect => 'Kaj zbiramo';

  @override
  String get networkMap_promptTitle => 'Pomagate graditi omrežni zemljevid?';

  @override
  String get networkMap_promptBody =>
      'MeshCore Open lahko deli, kaj sliši vaš radio, z javnim omrežnim zemljevidom na map.meshcoreopen.org, tako da vsi vidijo, kateri repeaterji obstajajo in kako so povezani.\n\nNikoli ne pošlje besedila sporočil, kdo se s kom pogovarja, imen kanalov, vaših stikov ali vašega natančnega položaja. Lokacije so zaokrožene na približno 2 km.';

  @override
  String get networkMap_promptSettingsHint =>
      'To lahko kadar koli spremenite v Nastavitve → Nastavitve aplikacije → Omrežni zemljevid.';

  @override
  String get networkMap_promptAccept => 'Deli';

  @override
  String get networkMap_promptDecline => 'Ne, hvala';

  @override
  String get networkMap_statusOff => 'Izklopljeno. Nič se ne pošilja.';

  @override
  String get networkMap_statusWaiting =>
      'Vklopljeno. Čakanje na povezavo z radiem.';

  @override
  String get networkMap_statusNothingSent => 'Vklopljeno. Še nič poslanega.';

  @override
  String networkMap_statusLastSent(String time, int count) {
    return 'Nazadnje poslano $time. Paketov danes: $count.';
  }

  @override
  String get networkMap_sourceLocal => 'Lokalno';

  @override
  String get networkMap_sourceOnline => 'Na spletu';

  @override
  String get networkMap_sourceBoth => 'Oboje';

  @override
  String get networkMap_zoomInHint =>
      'Povečajte, da vidite spletni omrežni zemljevid';

  @override
  String get networkMap_loadFailed =>
      'Spletnega omrežnega zemljevida ni bilo mogoče naložiti';

  @override
  String get networkMap_inYourContacts => 'V vaših stikih';

  @override
  String get networkMap_status => 'Stanje';

  @override
  String get networkMap_statusActive => 'Aktiven v zadnji uri';

  @override
  String get networkMap_statusRecent => 'Slišan v zadnjem dnevu';

  @override
  String get networkMap_statusStale => 'V zadnjem času ni bil slišan';

  @override
  String get networkMap_confirmed => 'Potrjeno';

  @override
  String get networkMap_singleSource => 'En vir, še ni potrjeno';

  @override
  String get networkMap_reports => 'Poročila';

  @override
  String get networkMap_locationEstimated =>
      'Približna lokacija, ocenjena glede na to, kdo ga je slišal';

  @override
  String get networkMap_locationAdvertised =>
      'Približna lokacija, iz njegovega lastnega adverta';

  @override
  String get networkMap_heardByRadio => 'Sliši ga vaš radio';

  @override
  String get networkMap_inYourArea => 'V vaši bližini';

  @override
  String get networkMap_farAway => 'Daleč stran. Upravljanje ne bo doseglo.';

  @override
  String get networkMap_addToContacts => 'Dodaj med stike';

  @override
  String get networkMap_manage => 'Upravljaj';

  @override
  String get networkMap_addedToContacts => 'Dodano med stike';

  @override
  String get networkMap_addFailed => 'Dodajanje med stike ni uspelo';

  @override
  String get networkMap_unnamed => 'Repeater brez imena';

  @override
  String get mediaMesh_title => 'MediaMesh Settings';

  @override
  String get mediaMesh_settingsSubtitle => 'Photos and voice on a second frequency';

  @override
  String get mediaMesh_noFirmware => 'This radio\'s firmware has no MediaMesh (radio2). Use Wadamesh, or MeshCore firmware with radio2 and media routing.';

  @override
  String get mediaMesh_cantRun => 'This radio can\'t run MediaMesh.';

  @override
  String get mediaMesh_noMediaRouting => 'This firmware has radio2 but cannot route media to it yet. Saving with radio2 on will fail until the radio is updated.';

  @override
  String get mediaMesh_mode => 'radio2';

  @override
  String get mediaMesh_modeOff => 'Off';

  @override
  String get mediaMesh_modeListen => 'Listen';

  @override
  String get mediaMesh_modeListenSend => 'Listen + send';

  @override
  String get mediaMesh_modeHelp => 'Listen hears photos and voice sent on radio2 but never sends there. Listen + send also sends. The main mesh is always heard.';

  @override
  String get mediaMesh_sentOn => 'Sent on radio2';

  @override
  String get mediaMesh_photosVoice => 'Photos & voice';

  @override
  String get mediaMesh_everything => 'Everything';

  @override
  String get mediaMesh_custom => 'Custom';

  @override
  String get mediaMesh_photosVoiceHelp => 'Photos and voice clips go on radio2. Text, adverts and ACKs stay on the main mesh.';

  @override
  String get mediaMesh_everythingHelp => 'Messages go on both radios and media follows each contact or channel, so radio2-only nodes hear everything.';

  @override
  String get mediaMesh_customHelp => 'Set from the radio console. Saving leaves it as it is.';

  @override
  String get mediaMesh_frequency => 'radio2 frequency (MHz)';

  @override
  String get mediaMesh_frequencyRange => 'Enter a frequency between 150 and 960 MHz';

  @override
  String get mediaMesh_frequencyMain => 'Must differ from the main radio';

  @override
  String get mediaMesh_footer => 'Everyone sharing photos must use the same radio2 settings. The radio switches between both frequencies, so heavy media traffic costs some main-mesh reception.';

  @override
  String get mediaMesh_saved => 'radio2 settings saved';

  @override
  String get mediaMesh_turnedOff => 'MediaMesh off';

  @override
  String get mediaMesh_status => 'Right now';

  @override
  String mediaMesh_packets(int rxMain, int rxRadio2, int txMain, int txRadio2) {
    return 'Received $rxMain main, $rxRadio2 radio2 · Sent $txMain main, $txRadio2 radio2';
  }

  @override
  String mediaMesh_switchTime(int micros) {
    return 'Switch time $micros µs';
  }

  @override
  String get mediaMesh_switchMeasuring => 'Switch time: measuring';

  @override
  String mediaMesh_warning(String text) {
    return 'Warning: $text';
  }

  @override
  String get mediaMesh_temporary => 'Temporary radio2';

  @override
  String get mediaMesh_temporaryHelp => 'Try the profile above for a while without saving it. The saved radio2 comes back afterwards, or on a reboot.';

  @override
  String get mediaMesh_temp15 => '15 min';

  @override
  String get mediaMesh_temp60 => '1 hour';

  @override
  String get mediaMesh_temp120 => '2 hours';

  @override
  String get mediaMesh_tempStop => 'Stop';

  @override
  String mediaMesh_tempRunning(String frequency, int minutes) {
    return 'Running: $frequency MHz, $minutes min left';
  }

  @override
  String get mediaMesh_tempStarted => 'Temporary radio2 started';

  @override
  String get mediaMesh_tempStopped => 'Saved radio2 restored';

  @override
  String get mediaMesh_openConsole => 'Radio console';

  @override
  String get mediaMesh_openConsoleSubtitle => 'Schedules, tempradio, diagnostics';

  @override
  String get txRoute_menu => 'Send on…';

  @override
  String txRoute_title(String name) {
    return 'Send $name on';
  }

  @override
  String get txRoute_auto => 'Auto';

  @override
  String get txRoute_radio => 'Main only';

  @override
  String get txRoute_radio2 => 'radio2 only';

  @override
  String get txRoute_both => 'Both';

  @override
  String get txRoute_off => 'Don\'t send';

  @override
  String get txRoute_help => 'Auto follows the MediaMesh settings. Only sending changes; this radio still hears both.';

  @override
  String get txRoute_boundByName => 'This #r2- channel always uses radio2. Rename it to change that.';

  @override
  String get txRoute_unsupported => 'This radio\'s firmware can\'t choose a radio per contact or channel.';

  @override
  String get txRoute_radio2Unavailable => 'radio2 can\'t send right now (off or listen only).';

  @override
  String txRoute_active(String where) {
    return 'Next message goes on: $where';
  }

  @override
  String get txRoute_none => 'nothing';

  @override
  String get radioConsole_title => 'Radio console';

  @override
  String get radioConsole_hint => 'e.g. get radio2.status';

  @override
  String get radioConsole_send => 'Send';

  @override
  String get radioConsole_intro => 'Commands run on the connected radio. Try: get mediamesh, get radio2.status, get radio2.timing, set tempradio2 off, tempradio, normalradio, get radioat2, get tx.media.';

  @override
  String get radioConsole_noReply => '(no reply)';

  @override
  String get radioConsole_failed => 'No answer from the radio';

  @override
  String get channels_scannedPrivateChannel => 'That code is for a private channel, so it is filled in under Join a Private Channel.';

  @override
  String get appUpdate_title => 'App update';

  @override
  String get appUpdate_settingsTile => 'App updates';

  @override
  String appUpdate_installed(String version, int build) {
    return 'Installed: $version (build $build)';
  }

  @override
  String appUpdate_available(String version, int build) {
    return 'Update available: $version (build $build)';
  }

  @override
  String get appUpdate_upToDate => 'You have the latest build';

  @override
  String get appUpdate_checking => 'Checking for updates…';

  @override
  String get appUpdate_notChecked => 'Not checked yet';

  @override
  String get appUpdate_localBuild => 'This is a local build, so updates are only checked when you ask. Installing a published build may need the app uninstalled first.';

  @override
  String get appUpdate_checkNow => 'Check now';

  @override
  String get appUpdate_install => 'Download and install';

  @override
  String get appUpdate_downloading => 'Downloading…';

  @override
  String appUpdate_downloadingPercent(int percent) {
    return 'Downloading… $percent%';
  }

  @override
  String get appUpdate_installing => 'Opening the installer…';

  @override
  String get appUpdate_installerHint => 'Android asks you to confirm the install. Your messages and settings stay.';

  @override
  String get appUpdate_permissionNeeded => 'Android needs your permission for MeshCore Open TAK to install updates. Turn on "Allow from this source", then come back and tap Download and install again.';

  @override
  String get appUpdate_openPermission => 'Open settings';

  @override
  String get appUpdate_debugSigned => 'This build is signed with a debug key, so Android will refuse to install it over the app you have. Uninstall first, or wait for a release-signed build.';

  @override
  String get appUpdate_changes => 'Recent changes';

  @override
  String get appUpdate_autoCheck => 'Check automatically';

  @override
  String get appUpdate_autoCheckHint => 'Every few hours, from the Latest build on GitHub';

  @override
  String appUpdate_checkFailed(String reason) {
    return 'Couldn\'t check for updates: $reason';
  }

  @override
  String appUpdate_installFailed(String reason) {
    return 'Update didn\'t install: $reason';
  }

  @override
  String get appUpdate_later => 'Later';

  @override
  String get appUpdate_view => 'Update';

  @override
  String get appUpdate_bannerTitle => 'A new version of MeshCore Open TAK is ready';

  @override
  String appUpdate_bannerSubtitle(String version, int build) {
    return '$version (build $build)';
  }

  @override
  String get vox_receivedViaMediaMesh => 'Received via MediaMesh';

  @override
  String get vox_receivedViaMainMesh => 'Received via main mesh';

  @override
  String get vox_receivedViaBoth => 'Received via MediaMesh and main mesh';

  @override
  String get appUpdate_installerHintWindows => 'The installer runs by itself: MeshCore Open TAK closes, updates and opens again. Your messages and settings stay.';

  @override
  String get appUpdate_installerHintMacos => 'The disk image opens. Drag MeshCore Open TAK to Applications, replace the old one, then open it again. Your messages and settings stay.';

  @override
  String get appUpdate_installerHintLinux => 'The AppImage replaces itself and MeshCore Open TAK restarts. Your messages and settings stay.';

  @override
  String get appUpdate_manualDownload => 'Updates install themselves only when you run the AppImage. Download the new build from GitHub.';

  @override
  String get appUpdate_noFileForPlatform => 'This build has no download for this computer yet. Check again later, or open the download page.';

  @override
  String get appUpdate_openDownloadPage => 'Open download page';

  @override
  String get rr2_hubTitle => 'MediaMesh (radio2)';

  @override
  String get rr2_hubSubtitle => 'Second frequency, bridging and live figures';

  @override
  String get rr2_title => 'MediaMesh';

  @override
  String get rr2_reload => 'Reload';

  @override
  String get rr2_asking => 'Asking the repeater…';

  @override
  String get rr2_loadFailed => 'The repeater didn\'t answer. Check that you\'re still logged in and in range.';

  @override
  String get rr2_noAnswer => 'No answer from the repeater';

  @override
  String rr2_refused(String reason) {
    return 'The repeater refused: $reason';
  }

  @override
  String rr2_applied(String reply) {
    return 'Applied: $reply';
  }

  @override
  String get rr2_turnedOff => 'radio2 turned off on the repeater';

  @override
  String get rr2_saved => 'Saved on the repeater';

  @override
  String get rr2_tempStarted => 'Temporary radio2 started';

  @override
  String get rr2_tempStopped => 'Temporary radio2 stopped; the saved radio2 is back';

  @override
  String get rr2_usbOnlyTitle => 'Needs USB';

  @override
  String get rr2_usbOnly => 'This repeater\'s firmware only takes radio2 changes over a USB cable. Bridging and replies can still be changed from here.';

  @override
  String get rr2_now => 'NOW';

  @override
  String get rr2_new => 'NEW';

  @override
  String get rr2_confirmTitle => 'Change radio2 on the repeater?';

  @override
  String get rr2_confirmOffTitle => 'Turn radio2 off?';

  @override
  String get rr2_confirmBody => 'The repeater answers first, then switches. If you reach it over radio2, you may lose contact until your radio uses the same settings.';

  @override
  String get rr2_confirmShared => 'Every node on this MediaMesh must use the same radio2 settings.';

  @override
  String get rr2_apply => 'Apply';

  @override
  String get rr2_turnOff => 'Turn off';

  @override
  String get rr2_unsupportedTitle => 'No radio2 on this repeater';

  @override
  String get rr2_unsupported => 'Its firmware doesn\'t know the radio2 commands. MediaMesh on a repeater needs MeshCore firmware with radio profiles (mikecarper/MeshCore).';

  @override
  String get rr2_unsupportedStock => 'It still forwards photos and voice heard on the main mesh, just never on radio2.';

  @override
  String get rr2_main => 'MAIN';

  @override
  String get rr2_linkBridged => 'BRIDGED';

  @override
  String get rr2_linkSeparate => 'SEPARATE';

  @override
  String get rr2_linkAuto => 'AUTO';

  @override
  String get rr2_chipOff => 'Off';

  @override
  String get rr2_chipListening => 'Listening on radio2';

  @override
  String get rr2_chipActive => 'Listening and sending';

  @override
  String rr2_chipTemp(int minutes) {
    return 'Temporary · $minutes min left';
  }

  @override
  String get rr2_chipPending => 'Change pending';

  @override
  String get rr2_liveSection => 'Live';

  @override
  String get rr2_refreshLive => 'Refresh live figures';

  @override
  String rr2_updatedSeconds(int seconds) {
    return '$seconds s ago';
  }

  @override
  String rr2_updatedMinutes(int minutes) {
    return '$minutes min ago';
  }

  @override
  String get rr2_noLive => 'No live figures from this repeater.';

  @override
  String get rr2_liveOff => 'radio2 is off, so there\'s nothing to count.';

  @override
  String get rr2_pending => 'A radio2 change is waiting for the repeater\'s reply to go out. It still uses the previous channel.';

  @override
  String get rr2_heardMain => 'Heard main';

  @override
  String get rr2_heardRadio2 => 'Heard radio2';

  @override
  String get rr2_sentMain => 'Sent main';

  @override
  String get rr2_sentRadio2 => 'Sent radio2';

  @override
  String rr2_heardShare(int percent) {
    return '$percent% of packets heard came in on radio2';
  }

  @override
  String get rr2_switchTime => 'Switch time';

  @override
  String get rr2_measuring => 'measuring';

  @override
  String get rr2_preambles => 'Preamble main / radio2 (symbols)';

  @override
  String get rr2_switches => 'Profile switches';

  @override
  String rr2_switchesErrors(int switches, int errors) {
    return '$switches ($errors failed)';
  }

  @override
  String get rr2_profileSection => 'radio2 profile';

  @override
  String get rr2_modeOffHelp => 'The repeater uses its main radio only.';

  @override
  String get rr2_modeRxHelp => 'The repeater also listens on radio2 but never sends there, unless replies are forced below.';

  @override
  String get rr2_modeRxtxHelp => 'The repeater listens and sends on radio2. Bridging below decides what crosses between the two.';

  @override
  String get rr2_frequency => 'Frequency';

  @override
  String get rr2_bw => 'Bandwidth';

  @override
  String get rr2_sf => 'SF';

  @override
  String get rr2_cr => 'CR';

  @override
  String rr2_faster(String times) {
    return 'About $times× faster on air than the main mesh';
  }

  @override
  String rr2_slower(String times) {
    return 'About $times× slower on air than the main mesh';
  }

  @override
  String get rr2_sameSpeed => 'About as fast on air as the main mesh';

  @override
  String get rr2_preambleAuto => 'Automatic preamble';

  @override
  String get rr2_preambleAutoHelp => 'Recommended. The repeater measures its switch time and picks the preamble.';

  @override
  String get rr2_preamble => 'Preamble';

  @override
  String get rr2_symbols => 'symbols';

  @override
  String get rr2_preambleRange => '8 to 512 symbols';

  @override
  String get rr2_sharedNote => 'The radio switches between both frequencies, so heavy radio2 traffic costs some main-mesh reception.';

  @override
  String get rr2_reset => 'Reset';

  @override
  String get rr2_applyToRepeater => 'Apply';

  @override
  String get rr2_crossSection => 'Bridging';

  @override
  String get rr2_crossOn => 'Bridge both ways';

  @override
  String get rr2_crossOnHelp => 'Forward what it hears on either radio onto the other.';

  @override
  String get rr2_crossAuto => 'Automatic';

  @override
  String get rr2_crossAutoHelp => 'Bridge the saved radio2; keep a temporary radio2 separate. The default.';

  @override
  String get rr2_crossOff => 'Keep separate';

  @override
  String get rr2_crossOffHelp => 'Each radio only forwards its own traffic.';

  @override
  String get rr2_notReported => 'This repeater doesn\'t report bridging.';

  @override
  String get rr2_replySection => 'Replies to admins';

  @override
  String get rr2_replyBoth => 'Both radios';

  @override
  String get rr2_replyBothHelp => 'Logins, CLI answers and ACKs go out on the main radio and radio2. The default.';

  @override
  String get rr2_replyMain => 'Main radio only';

  @override
  String get rr2_replyMainHelp => 'Keeps radio2 for media.';

  @override
  String get rr2_replyRadio2 => 'radio2 only';

  @override
  String get rr2_replyRadio2Help => 'No copy on the main radio. Only if you always admin it over radio2.';

  @override
  String get rr2_replyAuto => 'Follow bridging';

  @override
  String get rr2_replyAutoHelp => 'Replies follow the bridging setting above.';

  @override
  String get rr2_replyMissing => 'This firmware has no reply setting.';

  @override
  String get rr2_force => 'Also on a listen-only radio2';

  @override
  String get rr2_forceHelp => 'Lets replies go out on radio2 while it is set to Listen.';

  @override
  String get rr2_replyUnavailable => 'radio2 can\'t send right now, so these replies only go out on the main radio.';

  @override
  String get rr2_tempSection => 'Temporary radio2';

  @override
  String get rr2_tempHelp => 'Run the profile above for a while without saving it, for example to meet another group. The saved radio2 comes back afterwards, or on a reboot.';

  @override
  String get rr2_tempUses => 'USES';

  @override
  String rr2_tempRunning(String frequency) {
    return 'Temporary radio2 on $frequency MHz';
  }

  @override
  String get rr2_tempStop => 'Stop';

  @override
  String rr2_minutes(int minutes) {
    return '$minutes min';
  }

  @override
  String rr2_hours(int hours) {
    return '$hours h';
  }

  @override
  String rr2_hoursMinutes(int hours, int minutes) {
    return '$hours h $minutes min';
  }

  @override
  String rr2_left(String time) {
    return '$time left';
  }

  @override
  String get rr2_cli => 'Command line';

  @override
  String get rr2_cliSubtitle => 'Schedules, timing and every radio2 command';

  @override
  String get rr2_cliSection => 'MediaMesh (radio2)';

  @override
  String get rr2_cliNote => 'Needs repeater firmware with radio profiles. A remote radio2 change takes effect after the reply goes out.';

  @override
  String get rr2_cliGetRadio2 => 'Show the second radio profile';

  @override
  String get rr2_cliSetRadio2 => 'Set radio2: MHz, kHz, SF, CR, listen or listen+send';

  @override
  String get rr2_cliRadio2Off => 'Turn radio2 off';

  @override
  String get rr2_cliStatus => 'Packet counts, switch time and warnings';

  @override
  String get rr2_cliGetCross => 'Show bridging between the two radios';

  @override
  String get rr2_cliSetCross => 'Bridging: auto, on (both ways) or off (separate)';

  @override
  String get rr2_cliGetReply => 'Show where the repeater\'s replies go';

  @override
  String get rr2_cliSetReply => 'Where replies go; force allows a listen-only radio2';

  @override
  String get rr2_cliGetTemp => 'Show a running temporary radio2';

  @override
  String get rr2_cliSetTemp => 'Use other radio2 settings for some minutes';

  @override
  String get rr2_cliTempOff => 'End the temporary radio2';

  @override
  String get rr2_cliTiming => 'Preamble and switch timing details';

  @override
  String get settings_aboutRadioFirmware => 'Radio firmware';

  @override
  String get settings_aboutRadioNotConnected => 'No radio connected';

  @override
  String settings_aboutRadioFirmwareOn(String firmware, String board) {
    return '$firmware on $board';
  }

  @override
  String settings_aboutRadioBuild(String date) {
    return 'Built $date';
  }

  @override
  String settings_aboutRadioBoard(String board) {
    return 'Board: $board';
  }

  @override
  String settings_aboutRadioProtocol(int code) {
    return 'Companion protocol v$code';
  }

  @override
  String startup_stalled(String steps) {
    return 'Startup skipped a step that didn\'t finish: $steps. The app may be missing something until it restarts.';
  }

  @override
  String get mediaMesh_shareMain => 'Share with main-mesh nodes';

  @override
  String get mediaMesh_shareMainOff => 'Off: photo and voice requests and answers stay on radio2, so nodes without it can\'t swap them with you.';

  @override
  String get mediaMesh_shareMainOn => 'On: requests go out on both radios, and a photo or clip asked for on the main mesh is answered there.';

  @override
  String get mediaMesh_preset => 'Preset';

  @override
  String get mediaMesh_presetFast => '250 kHz · fast';

  @override
  String get mediaMesh_presetRange => '125 kHz · range';

  @override
  String get mediaMesh_presetHelp => '250 kHz sends photos and voice about twice as fast; 125 kHz reaches about 40% farther. Every radio on MediaMesh must use the same settings.';

  @override
  String mediaMesh_conflictsWith(String name) {
    return 'Conflicts with $name';
  }

  @override
  String get mediaMeshNearby_heardNow => 'MediaMesh nearby: heard just now';

  @override
  String mediaMeshNearby_heardAgo(int minutes) {
    return 'MediaMesh nearby: heard $minutes min ago';
  }

  @override
  String get mediaMeshNearby_listening => 'Listening for a MediaMesh: none heard in the last 2 hours';

  @override
  String get mediaMeshNearby_off => 'MediaMesh is off on this radio. Tap to set it up.';

  @override
  String get mapHighlight_title => 'Highlight new map points';

  @override
  String get mapHighlight_help => 'A teammate, pin, report or watched-channel point that appears on the map flashes with a ring for this long.';

  @override
  String get mapHighlight_off => 'Off';

  @override
  String mapHighlight_minutes(int minutes) {
    return '$minutes min';
  }

  @override
  String get mediaMesh_modeOn => 'On';

  @override
  String get mediaMesh_modeOnHelp => 'On listens and sends on radio2 (MediaMesh). The main mesh is always heard.';

  @override
  String get mediaMesh_listenOnlyNote => 'Set to listen only (from the console): it hears radio2 but never sends there. Tap On to send too.';

  @override
  String get sound_title => 'Sound link';

  @override
  String get sound_settingsSubtitle => 'Messages and share links over sound, Wavest-compatible';

  @override
  String get sound_unavailable => 'This build has no sound link.';

  @override
  String get sound_intro => 'Sends short messages as tones from the speaker and hears them on the microphone (ggwave), in the same format as Wavest (bennjordan.github.io/Wavest), so a T-Deck, another phone or a Wavest page in a browser can join in. A message is a few seconds of sound, up to about 120 characters.';

  @override
  String get sound_settings => 'Callsign, passkey and sound';

  @override
  String get sound_callsign => 'Callsign';

  @override
  String get sound_passkey => 'Passkey (optional)';

  @override
  String get sound_passkeyHelp => 'Encrypts what you send and opens what others send with the same passkey, as Wavest does (AES-GCM). It keeps a chat from bystanders; it is not the mesh\'s own encryption.';

  @override
  String get sound_mode => 'Sound';

  @override
  String get sound_volume => 'Volume';

  @override
  String get sound_modeAudibleNormal => 'Audible: normal (most robust)';

  @override
  String get sound_modeAudibleFast => 'Audible: fast (Wavest\'s default)';

  @override
  String get sound_modeAudibleFastest => 'Audible: fastest';

  @override
  String get sound_modeUltraNormal => 'Ultrasound: normal (phones only)';

  @override
  String get sound_modeUltraFast => 'Ultrasound: fast (phones only)';

  @override
  String get sound_modeUltraFastest => 'Ultrasound: fastest (phones only)';

  @override
  String get sound_bridge => 'Bridge to a channel';

  @override
  String get sound_bridgeOff => 'Off';

  @override
  String get sound_bridgeChannel => 'Channel';

  @override
  String get sound_bridgePlay => 'Play this channel\'s new messages as sound';

  @override
  String get sound_bridgeHelp => 'What is heard is posted to the channel as "[Wavest] callsign: text". With this on, the channel\'s new messages are played too, so people nearby without a radio can follow and reply.';

  @override
  String get sound_shareContact => 'Play my contact';

  @override
  String get sound_shareChannel => 'Play a channel';

  @override
  String get sound_messageHint => 'Message to play';

  @override
  String get sound_send => 'Play';

  @override
  String get sound_tooLong => 'Too long for one sound message. Shorten it (a passkey makes it longer).';

  @override
  String get sound_listen => 'Listen for it by sound';

  @override
  String get sound_listening => 'Listening…';

  @override
  String get sound_listeningHelp => 'Hold this phone near the other device and play the contact or channel there (Play by sound).';

  @override
  String get sound_notListening => 'Turn on listening (top right) to hear messages.';

  @override
  String sound_heardOther(String text) {
    return 'Heard something else: $text';
  }

  @override
  String get sound_heardRaw => 'Heard';

  @override
  String get sound_locked => 'Encrypted: set the same passkey to read it';

  @override
  String get sound_linkHint => 'A share link. Add it from Contacts or Channels: Scan, then Listen.';

  @override
  String get sound_playByShare => 'Play by sound';

  @override
  String get sound_playing => 'Playing…';

  @override
  String get sound_playByShareHelp => 'For a T-Deck or another phone: they listen (Scan, then Listen) while this plays.';

  @override
  String sound_playFailed(String error) {
    return 'Couldn\'t play it: $error';
  }

  @override
  String get otpCheck_title => 'Check code';

  @override
  String get otpCheck_subtitle => 'The same code on both devices means the same pad. Read it out, or play it by sound; it reveals nothing about the pad.';

  @override
  String get otpCheck_play => 'Play the check code';

  @override
  String get otpCheck_listen => 'Listen for a check code';

  @override
  String get otpCheck_same => 'Same pad on both devices.';

  @override
  String get otpCheck_different => 'Different pad bytes. Share the pad again before using it.';

  @override
  String otpCheck_differentLength(int theirs, int mine) {
    return 'Different pad: theirs is $theirs bytes, this one $mine. Share it again before using it.';
  }

  @override
  String get otpCheck_heard => 'Pad check';

  @override
  String otpCheck_matches(String name) {
    return 'Same pad as $name.';
  }

  @override
  String get otpCheck_noMatch => 'No pad here matches this check code.';

  @override
  String get otpCheck_locked => 'Unlock OTP to compare this check code.';

  @override
  String get road_directions => 'Directions';

  @override
  String road_directionsTo(String target) {
    return 'Directions to $target';
  }

  @override
  String get road_drive => 'Drive';

  @override
  String get road_walk => 'Walk';

  @override
  String get road_bike => 'Bike';

  @override
  String get road_help => 'Turn-by-turn along roads and paths, from OpenStreetMap. Needs the internet; Bloodhound keeps range and bearing without it. It finds a new route if you leave this one or your teammate moves.';

  @override
  String get road_server => 'Routing server (Valhalla)';

  @override
  String get road_serverHelp => 'Empty: the public FOSSGIS server, for light use. Put your own Valhalla server here for a team.';

  @override
  String get road_finding => 'Finding a route...';

  @override
  String road_then(String distance) {
    return 'In $distance';
  }

  @override
  String road_left(String distance, String time) {
    return '$distance · $time to go';
  }

  @override
  String get road_arrived => 'You have arrived';

  @override
  String get road_share => 'Share with team';

  @override
  String get road_shared => 'Route shared with the team: phones and standalone radios can follow it';

  @override
  String get road_stop => 'Stop directions';

  @override
  String get road_retry => 'Try again';

  @override
  String get road_turnSlightLeft => 'Slight left';

  @override
  String get road_turnLeft => 'Turn left';

  @override
  String get road_turnSharpLeft => 'Sharp left';

  @override
  String get road_turnSlightRight => 'Slight right';

  @override
  String get road_turnRight => 'Turn right';

  @override
  String get road_turnSharpRight => 'Sharp right';

  @override
  String get road_uTurn => 'U-turn';

  @override
  String road_turnIn(String turn, String distance, String left) {
    return '$turn in $distance · $left left';
  }

  @override
  String road_arriveIn(String distance) {
    return 'Arrive in $distance';
  }

  @override
  String get hound_title => 'Bloodhound';

  @override
  String get hound_help => 'Live range and bearing to a target, and directions to it.';

  @override
  String get hound_teammates => 'Teammates';

  @override
  String get hound_nodes => 'Nodes with a position (nearest first)';

  @override
  String get hound_watched => 'Watched reports on the map';

  @override
  String get hound_mapCentre => 'Centre of the map';

  @override
  String get hound_noTeammates => 'No teammates heard yet';

  @override
  String get hound_noNodes => 'No nodes with a position yet';

  @override
  String hound_away(String distance) {
    return '$distance away';
  }

  @override
  String road_sayIn(String distance, String what) {
    return 'In $distance, $what';
  }

  @override
  String road_sayMeters(String n) {
    return '$n meters';
  }

  @override
  String road_sayKilometers(String n) {
    return '$n kilometers';
  }

  @override
  String get road_sayTurnLeft => 'Turn left';

  @override
  String get road_sayTurnRight => 'Turn right';

  @override
  String get road_sayBearLeft => 'Bear left';

  @override
  String get road_sayBearRight => 'Bear right';

  @override
  String get road_saySharpLeft => 'Turn sharp left';

  @override
  String get road_saySharpRight => 'Turn sharp right';

  @override
  String get road_sayUTurn => 'Make a U-turn';

  @override
  String get road_sayArrived => 'You have arrived.';

  @override
  String get road_sayRerouting => 'Rerouting.';

  @override
  String get road_voiceOn => 'Spoken directions on';

  @override
  String get road_voiceOff => 'Spoken directions off';

  @override
  String get mediaMesh_find => 'Find MediaMesh';

  @override
  String get mediaMesh_findHelp => 'Asks the repeaters in range which radio2 profile they run, like Discover Repeaters. If none can say, radio2 listens on each preset for about 10 seconds instead.';

  @override
  String mediaMesh_findListening(String preset, int step) {
    return 'Listening on $preset ($step/2)…';
  }

  @override
  String mediaMesh_findFound(String preset, int count) {
    return 'MediaMesh found on $preset: $count packets heard on radio2. Use this preset?';
  }

  @override
  String mediaMesh_findNone(String frequency) {
    return 'No MediaMesh answered on 250 or 125 kHz at $frequency MHz.';
  }

  @override
  String get mediaMesh_findNoneOnRadio2 => 'Repeaters nearby answered on the main mesh, but none on radio2.';

  @override
  String get mediaMesh_findNoRepeaters => 'No repeaters answered at all: out of range, or asked too often. Repeaters answer at most four times in two minutes, so try again shortly.';

  @override
  String get mediaMesh_findUse => 'Use it';
  String get walkie_title => 'Walkie-talkie';

  @override
  String get walkie_tooltip => 'Walkie-talkie (push to talk)';

  @override
  String get walkie_holdToTalk => 'Hold to talk';

  @override
  String get walkie_onAir => 'On air';

  @override
  String get walkie_releaseToSend => 'Let go to finish';

  @override
  String get walkie_starting => 'Starting…';

  @override
  String get walkie_finishing => 'Finishing…';

  @override
  String get walkie_clear => 'Channel clear';

  @override
  String get walkie_someoneTalking => 'Someone is talking';

  @override
  String walkie_nameTalking(String name) {
    return '$name is talking';
  }

  @override
  String walkie_lastTalk(String name) {
    return 'Last talk: $name';
  }

  @override
  String get walkie_reach => 'Reach';

  @override
  String get walkie_viaRepeaters => 'Repeaters';

  @override
  String get walkie_direct => 'Direct';

  @override
  String get walkie_repeatersHelp => 'Through repeaters: reaches the whole MediaMesh, with about 2–3 seconds of delay.';

  @override
  String get walkie_directHelp => 'Radio to radio: only radios in range hear it. A little faster, and no repeater traffic.';

  @override
  String get walkie_listenLive => 'Play this channel\'s talks live';

  @override
  String get walkie_listenLiveHelp => 'Off mutes this channel: its talks wait in the chat as voice messages.';

  @override
  String walkie_footer(int seconds) {
    return 'Up to $seconds seconds a talk. Talks go out on MediaMesh only, and each one is saved in the chat as a voice message. On a computer, hold Space to talk.';
  }

  @override
  String get drones_title => 'Drone detector';

  @override
  String get drones_chip => 'Drones';

  @override
  String get drones_listen => 'Listen for drones';

  @override
  String get drones_listenHelp => 'Hears drones that broadcast Remote ID over Bluetooth: their ID, position, height, speed and where the operator is. Drones without Remote ID aren\'t detected.';

  @override
  String get drones_scanning => 'Listening';

  @override
  String get drones_paused => 'Paused while the app searches for radios';

  @override
  String get drones_none => 'No drones heard yet.';

  @override
  String get drones_noPosition => 'no position yet';

  @override
  String get drones_stale => 'not heard for a minute';

  @override
  String get drones_type => 'Type';

  @override
  String get drones_height => 'Height';

  @override
  String get drones_altitude => 'Altitude';

  @override
  String get drones_speed => 'Speed';

  @override
  String get drones_heading => 'Heading';

  @override
  String get drones_operator => 'Operator';

  @override
  String get drones_operatorId => 'Operator ID';

  @override
  String get drones_description => 'Description';

  @override
  String get drones_signal => 'Signal';

  @override
  String get drones_lastHeard => 'Last heard';

  @override
  String get drones_showOnMap => 'Show on map';

  @override
  String get drones_post => 'Post to the alert channel';

  @override
  String get drones_posted => 'Posted';

  @override
  String get drones_alertChannel => 'Alert channel';

  @override
  String get drones_noChannel => 'None';

  @override
  String get drones_share => 'Post drones there';

  @override
  String get drones_shareHelp => 'Each drone at most once a minute, and again after it moves 200 m. Never on Public. Others watching the channel see them on their map, with the operator.';

  @override
  String get drones_sound => 'Sound when a new drone appears';

  @override
  String get drones_clear => 'Clear the list';

  @override
  String drones_counts(int heard, int posted) {
    return '$heard broadcasts heard · $posted posted';
  }

  @override
  String drones_secondsAgo(int n) {
    return '$n s ago';
  }

  @override
  String drones_minutesAgo(int n) {
    return '$n min ago';
  }

  @override
  String get mediaMesh_findAsking => 'Asking repeaters nearby…';

  @override
  String mediaMesh_findReported(int count, int total, String profile) {
    return '$count of $total repeaters nearby run radio2 on $profile.';
  }

  @override
  String get mediaMesh_findReportedNone => 'Repeaters nearby answered, but none has radio2 on.';

  @override
  String get mediaMesh_findRadio2Off => 'radio2 off';

  @override
  String get mediaMesh_findNotSaid => 'didn\'t say';

  @override
  String get mediaMesh_findListenOnly => 'listen only';

  @override
  String get mediaMesh_findTemporary => 'temporary';

  @override
  String drones_joinDefault(String channel) {
    return 'Join $channel';
  }

  @override
  String drones_notJoined(String channel) {
    return '$channel (not joined)';
  }

  @override
  String get walkie_liveAll => 'Play talks live';

  @override
  String get walkie_liveAllHelp => 'Talks on any channel play as they arrive, while the app is running, walkie-talkie open or not.';

  @override
  String get coverage_title => 'Coverage map';

  @override
  String get coverage_record => 'Map MediaMesh coverage';

  @override
  String get coverage_recordHelp => 'As you move, asks the MediaMesh repeaters in range every 150 m and marks the map with how well MediaMesh reaches there.';

  @override
  String get coverage_asking => 'Asking the MediaMesh repeaters…';

  @override
  String get coverage_show => 'Show on the map';

  @override
  String coverage_points(int count) {
    return '$count points';
  }

  @override
  String get coverage_good => 'Good';

  @override
  String get coverage_marginal => 'Marginal';

  @override
  String get coverage_out => 'Out';

  @override
  String get coverage_none => 'None';

  @override
  String get coverage_help => 'Only repeaters with MediaMesh (radio2 on) count. Good: 5 dB or more to spare on radio2; Marginal: 0–5 dB; Out: heard, but radio2 wouldn\'t reach; None: no MediaMesh repeater answered.';

  @override
  String get coverage_export => 'Export (GeoJSON)';

  @override
  String get coverage_clear => 'Clear';

  @override
  String get teamSetup_noTeam => 'Pick a team channel first';

  @override
  String get teamSetup_share => 'Share team setup';

  @override
  String get teamSetup_shareTitle => 'Share this team';

  @override
  String teamSetup_playingPart(int part, int parts) {
    return 'Playing part $part of $parts…';
  }

  @override
  String teamSetup_soundHelp(int parts) {
    return 'For a standalone without a camera: Sound link hears it, in $parts part(s) of a few seconds each.';
  }

  @override
  String get teamSetup_shareWarning => 'Anyone who scans or hears this can join your team channel and see your positions.';

  @override
  String teamSetup_teamChannel(String name) {
    return 'Team channel: $name';
  }

  @override
  String get teamSetup_teamChannelHelp => 'Added if this radio hasn\'t it, and team mode turned on with it.';

  @override
  String teamSetup_watch(String names) {
    return 'Watch: $names';
  }

  @override
  String get teamSetup_watchHelp => 'Added if needed, and their reports shown on the map.';

  @override
  String teamSetup_mediaMesh(String profile) {
    return 'MediaMesh: $profile';
  }

  @override
  String get teamSetup_mediaMeshHelp => 'This radio\'s radio2 set to the team\'s MediaMesh, for photos, voice and push-to-talk.';

  @override
  String get teamSetup_joinTitle => 'Join a team';

  @override
  String get teamSetup_join => 'Join';

  @override
  String get teamSetup_notATeam => 'That isn\'t a team setup code';

  @override
  String get teamSetup_scanHelp => 'Scan the team code on a teammate\'s phone or standalone';

  @override
  String get teamSetup_listenHelp => 'Waiting for the team setup to be played…';

  @override
  String teamSetup_heardParts(int got, int total) {
    return 'Heard $got of $total parts…';
  }

  @override
  String get teamSetup_notConnected => 'Connect to your radio first';

  @override
  String teamSetup_noSlot(String name) {
    return 'No free channel slot for $name';
  }

  @override
  String get teamSetup_noMediaMesh => 'This radio has no MediaMesh (radio2)';

  @override
  String teamSetup_joined(String name) {
    return 'Joined $name';
  }

  @override
  String get appSettings_redLight => 'Red light (night vision)';

  @override
  String get appSettings_redLightHelp => 'Everything in dim red, the map and photos too, to keep your eyes used to the dark.';

  @override
  String get quickReply_copy => 'Copy';

  @override
  String get quickReply_onMyWay => 'On my way';

  @override
  String get quickReply_eta => 'ETA…';

  @override
  String quickReply_etaMin(int minutes) {
    return 'ETA $minutes min';
  }

  @override
  String get quickReply_etaPick => 'How long until you\'re there?';

  @override
  String get quickReply_cantHelp => 'Can\'t help';

  @override
  String get quickReply_seenIt => 'Seen it';

  @override
  String get quickReply_needBackup => 'Need backup';

  @override
  String get quickReply_allClear => 'All clear';

  @override
  String get quickReply_you => 'You';

  @override
  String get quickReply_now => 'now';

  @override
  String get quickReply_answers => 'Answers';

  @override
  String get quickReply_answerAlert => 'Answer (also acknowledges)';

  @override
  String quickReply_summary(int count, String who) {
    return '$count answered: $who';
  }

  @override
  String get reach_title => 'Who got it';

  @override
  String get reach_action => 'Who got it (map)';

  @override
  String get reach_noPosition => 'This radio has no position, so there\'s nothing to draw from. The lists below still show who got it.';

  @override
  String reach_summary(int repeaters, int teammates) {
    return '$repeaters repeaters re-sent it · $teammates teammates heard it';
  }

  @override
  String get reach_noRepeats => 'No repeater has been heard re-sending it yet. Echoes show up here as they come in.';

  @override
  String get reach_direct => 'Heard you directly';

  @override
  String reach_hops(int hops) {
    return '$hops hops out';
  }

  @override
  String get reach_noLocation => 'location unknown';

  @override
  String get reach_teammates => 'Teammates';

  @override
  String reach_heardAgo(String ago) {
    return 'Heard it · $ago';
  }

  @override
  String get reach_notYet => 'Not heard yet';

  @override
  String get reach_teamHelp => 'Teammates say what they heard in their next position beacon, usually within a minute. Older app and firmware versions don\'t, so they stay "Not heard yet".';

  @override
  String get reach_now => 'just now';

  @override
  String get ar_title => 'AR view';

  @override
  String get ar_noPosition => 'Waiting for your position: labels appear once the phone has a GPS fix.';

  @override
  String ar_noCompass(String reason) {
    return 'The compass isn\'t available ($reason), so labels can\'t be placed.';
  }

  @override
  String ar_hounding(String name) {
    return 'Bloodhound: $name';
  }
}
