# Сводный индекс спецификаций формата XML конфигурации 1С

Единая точка входа ко всем спецификациям XML-формата выгрузки 1С:Предприятие 8.3.

---

## 1. Корневые файлы конфигурации

| Файл | Описание | Спецификация |
|------|----------|--------------|
| `Configuration.xml` | Свойства и состав конфигурации | [specs/1c-configuration-spec.md § 2](specs/1c-configuration-spec.md#2-configurationxml--корневой-файл-конфигурации) |
| `ConfigDumpInfo.xml` | Версии объектов (служебный) | [specs/1c-configuration-spec.md § 3](specs/1c-configuration-spec.md#3-configdumpinfoxml--служебный-файл-выгрузки) |
| `Ext/` | Модули, интерфейс, начальная страница | [specs/1c-configuration-spec.md § 4](specs/1c-configuration-spec.md#4-ext--корневой-каталог-конфигурации) |
| `Languages/` | Языки конфигурации | [specs/1c-configuration-spec.md § 5](specs/1c-configuration-spec.md#5-языки-languages) |

---

## 2. Объекты метаданных

Все типы объектов, встречающиеся в `ChildObjects` корневого `Configuration.xml`. Порядок соответствует порядку в XML.

### Служебные и интерфейсные

| XML-элемент | Каталог | Русское название | Спецификация |
|-------------|---------|-----------------|--------------|
| `Language` | `Languages/` | Языки | [specs/1c-configuration-spec.md § 5](specs/1c-configuration-spec.md#5-языки-languages) |
| `Subsystem` | `Subsystems/` | Подсистемы | [specs/1c-subsystem-spec.md § 3](specs/1c-subsystem-spec.md#3-формат-подсистемы) |
| `StyleItem` | `StyleItems/` | Элементы стиля | [specs/1c-configuration-spec.md § 6.16](specs/1c-configuration-spec.md#616-styleitem--элемент-стиля) |
| `Style` | `Styles/` | Стили (устаревший) | [specs/1c-configuration-spec.md § 6.17](specs/1c-configuration-spec.md#617-style--стиль-устаревший) |
| `CommandGroup` | `CommandGroups/` | Группы команд | [specs/1c-subsystem-spec.md § 5](specs/1c-subsystem-spec.md#5-формат-группы-команд-commandgroup) |

### Общие объекты

| XML-элемент | Каталог | Русское название | Спецификация |
|-------------|---------|-----------------|--------------|
| `CommonPicture` | `CommonPictures/` | Общие картинки | [specs/1c-configuration-spec.md § 6.1](specs/1c-configuration-spec.md#61-commonpicture--общая-картинка) |
| `SessionParameter` | `SessionParameters/` | Параметры сеанса | [specs/1c-configuration-spec.md § 6.6](specs/1c-configuration-spec.md#66-sessionparameter--параметр-сеанса) |
| `Role` | `Roles/` | Роли | [specs/1c-role-spec.md § Файл метаданных](specs/1c-role-spec.md#файл-метаданных-rolesимяролиxml) |
| `CommonTemplate` | `CommonTemplates/` | Общие макеты | [specs/1c-configuration-spec.md § 6.2](specs/1c-configuration-spec.md#62-commontemplate--общий-макет) |
| `FilterCriterion` | `FilterCriteria/` | Критерии отбора | [specs/1c-configuration-spec.md § 6.11](specs/1c-configuration-spec.md#611-filtercriterion--критерий-отбора) |
| `CommonModule` | `CommonModules/` | Общие модули | [specs/1c-config-objects-spec.md § 21](specs/1c-config-objects-spec.md#21-общие-модули-commonmodules) |
| `CommonAttribute` | `CommonAttributes/` | Общие реквизиты | [specs/1c-configuration-spec.md § 6.3](specs/1c-configuration-spec.md#63-commonattribute--общий-реквизит) |
| `CommonCommand` | `CommonCommands/` | Общие команды | [specs/1c-subsystem-spec.md § 6](specs/1c-subsystem-spec.md#6-формат-общей-команды-commoncommand) |
| `CommonForm` | `CommonForms/` | Общие формы | [specs/1c-configuration-spec.md § 6.4](specs/1c-configuration-spec.md#64-commonform--общая-форма) |

### Интеграция и сервисы

| XML-элемент | Каталог | Русское название | Спецификация |
|-------------|---------|-----------------|--------------|
| `ExchangePlan` | `ExchangePlans/` | Планы обмена | [specs/1c-config-objects-spec.md § 15](specs/1c-config-objects-spec.md#15-планы-обмена-exchangeplans) |
| `XDTOPackage` | `XDTOPackages/` | XDTO-пакеты | [specs/1c-configuration-spec.md § 6.14](specs/1c-configuration-spec.md#614-xdtopackage--xdto-пакет) |
| `WebService` | `WebServices/` | Веб-сервисы | [specs/1c-config-objects-spec.md § 25](specs/1c-config-objects-spec.md#25-веб-сервисы-webservices) |
| `HTTPService` | `HTTPServices/` | HTTP-сервисы | [specs/1c-config-objects-spec.md § 24](specs/1c-config-objects-spec.md#24-http-сервисы-httpservices) |
| `WSReference` | `WSReferences/` | WS-ссылки | [specs/1c-configuration-spec.md § 6.15](specs/1c-configuration-spec.md#615-wsreference--ws-ссылка) |
| `IntegrationService` | `IntegrationServices/` | Сервисы интеграции | [specs/1c-configuration-spec.md § 6.13](specs/1c-configuration-spec.md#613-integrationservice--сервис-интеграции) |

### Поведение и параметризация

| XML-элемент | Каталог | Русское название | Спецификация |
|-------------|---------|-----------------|--------------|
| `EventSubscription` | `EventSubscriptions/` | Подписки на события | [specs/1c-config-objects-spec.md § 23](specs/1c-config-objects-spec.md#23-подписки-на-события-eventsubscriptions) |
| `ScheduledJob` | `ScheduledJobs/` | Регламентные задания | [specs/1c-config-objects-spec.md § 22](specs/1c-config-objects-spec.md#22-регламентные-задания-scheduledjobs) |
| `SettingsStorage` | `SettingsStorages/` | Хранилища настроек | [specs/1c-configuration-spec.md § 6.10](specs/1c-configuration-spec.md#610-settingsstorage--хранилище-настроек) |
| `FunctionalOption` | `FunctionalOptions/` | Функциональные опции | [specs/1c-configuration-spec.md § 6.7](specs/1c-configuration-spec.md#67-functionaloption--функциональная-опция) |
| `FunctionalOptionsParameter` | `FunctionalOptionsParameters/` | Параметры ФО | [specs/1c-configuration-spec.md § 6.8](specs/1c-configuration-spec.md#68-functionaloptionsparameter--параметр-функциональных-опций) |
| `DefinedType` | `DefinedTypes/` | Определяемые типы | [specs/1c-config-objects-spec.md § 20](specs/1c-config-objects-spec.md#20-определяемые-типы-definedtypes) |
| `Constant` | `Constants/` | Константы | [specs/1c-config-objects-spec.md § 17](specs/1c-config-objects-spec.md#17-константы-constants) |

### Прикладные объекты

| XML-элемент | Каталог | Русское название | Спецификация |
|-------------|---------|-----------------|--------------|
| `Catalog` | `Catalogs/` | Справочники | [specs/1c-config-objects-spec.md § 7](specs/1c-config-objects-spec.md#7-справочники-catalogs) |
| `Document` | `Documents/` | Документы | [specs/1c-config-objects-spec.md § 8](specs/1c-config-objects-spec.md#8-документы-documents) |
| `DocumentNumerator` | `DocumentNumerators/` | Нумераторы документов | [specs/1c-configuration-spec.md § 6.12](specs/1c-configuration-spec.md#612-documentnumerator--нумератор-документов) |
| `Sequence` | `Sequences/` | Последовательности | [specs/1c-configuration-spec.md § 6.9](specs/1c-configuration-spec.md#69-sequence--последовательность-документов) |
| `DocumentJournal` | `DocumentJournals/` | Журналы документов | [specs/1c-config-objects-spec.md § 19](specs/1c-config-objects-spec.md#19-журналы-документов-documentjournals) |
| `Enum` | `Enums/` | Перечисления | [specs/1c-config-objects-spec.md § 16](specs/1c-config-objects-spec.md#16-перечисления-enums) |
| `Report` | `Reports/` | Отчёты | [specs/1c-config-objects-spec.md § 18](specs/1c-config-objects-spec.md#18-отчёты-и-обработки) |
| `DataProcessor` | `DataProcessors/` | Обработки | [specs/1c-config-objects-spec.md § 18](specs/1c-config-objects-spec.md#18-отчёты-и-обработки) |

### Регистры

| XML-элемент | Каталог | Русское название | Спецификация |
|-------------|---------|-----------------|--------------|
| `InformationRegister` | `InformationRegisters/` | Регистры сведений | [specs/1c-config-objects-spec.md § 9.1](specs/1c-config-objects-spec.md#91-регистры-сведений-informationregisters) |
| `AccumulationRegister` | `AccumulationRegisters/` | Регистры накопления | [specs/1c-config-objects-spec.md § 9.4](specs/1c-config-objects-spec.md#94-регистры-накопления-accumulationregisters) |
| `AccountingRegister` | `AccountingRegisters/` | Регистры бухгалтерии | [specs/1c-config-objects-spec.md § 9.5](specs/1c-config-objects-spec.md#95-регистры-бухгалтерии-accountingregisters) |
| `CalculationRegister` | `CalculationRegisters/` | Регистры расчёта | [specs/1c-config-objects-spec.md § 9.6](specs/1c-config-objects-spec.md#96-регистры-расчёта-calculationregisters) |

### Планы

| XML-элемент | Каталог | Русское название | Спецификация |
|-------------|---------|-----------------|--------------|
| `ChartOfCharacteristicTypes` | `ChartsOfCharacteristicTypes/` | Планы видов характеристик | [specs/1c-config-objects-spec.md § 11](specs/1c-config-objects-spec.md#11-планы-видов-характеристик-chartsofcharacteristictypes) |
| `ChartOfAccounts` | `ChartsOfAccounts/` | Планы счетов | [specs/1c-config-objects-spec.md § 10](specs/1c-config-objects-spec.md#10-планы-счетов-chartsofaccounts) |
| `ChartOfCalculationTypes` | `ChartsOfCalculationTypes/` | Планы видов расчёта | [specs/1c-config-objects-spec.md § 12](specs/1c-config-objects-spec.md#12-планы-видов-расчёта-chartsofcalculationtypes) |

### Бизнес-процессы

| XML-элемент | Каталог | Русское название | Спецификация |
|-------------|---------|-----------------|--------------|
| `BusinessProcess` | `BusinessProcesses/` | Бизнес-процессы | [specs/1c-config-objects-spec.md § 13](specs/1c-config-objects-spec.md#13-бизнес-процессы-businessprocesses) |
| `Task` | `Tasks/` | Задачи | [specs/1c-config-objects-spec.md § 14](specs/1c-config-objects-spec.md#14-задачи-tasks) |

---

## 3. Вложенные форматы

Форматы файлов, вложенных в каталоги объектов метаданных.

| Формат | Файл | Описание | Спецификация |
|--------|------|----------|--------------|
| Управляемая форма | `Ext/Form.xml` | Элементы, реквизиты, команды | [specs/1c-form-spec.md § 1](specs/1c-form-spec.md#1-корневой-элемент) |
| СКД (DataCompositionSchema) | `Ext/Template.xml` | Схема компоновки данных | [specs/1c-dcs-spec.md § 2](specs/1c-dcs-spec.md#2-общая-структура-datacompositionschema) |
| Табличный документ (MXL) | `Ext/Template.xml` | Печатная форма | [specs/1c-spreadsheet-spec.md](specs/1c-spreadsheet-spec.md#структура-документа) |
| Роль (Rights) | `Ext/Rights.xml` | Права доступа и RLS | [specs/1c-role-spec.md](specs/1c-role-spec.md#файл-прав-rolesимяролиextrightsxml) |
| Справка (Help) | `Ext/Help/` | Встроенная справка | [specs/1c-help-spec.md § 1](specs/1c-help-spec.md#1-структура-файлов) |
| Предопределённые элементы | `Predefined.xml` | Предопределённые справочники/ПВХ | [specs/1c-config-objects-spec.md § 7.2](specs/1c-config-objects-spec.md#72-предопределённые-элементы-predefinedxml) |
| Состав плана обмена | `Content.xml` | Объекты синхронизации | [specs/1c-config-objects-spec.md § 15.4](specs/1c-config-objects-spec.md#154-состав-плана-обмена-contentxml) |
| Карта маршрута | `Flowchart.xml` | Маршрут бизнес-процесса | [specs/1c-config-objects-spec.md § 13.3](specs/1c-config-objects-spec.md#133-карта-маршрута-flowchartxml) |

---

## 4. Расширения конфигурации (CFE)

| Тема | Описание | Спецификация |
|------|----------|--------------|
| Общая структура выгрузки | Каталоги, отличия от конфигурации | [specs/1c-extension-spec.md § 1](specs/1c-extension-spec.md#1-общая-структура-выгрузки-расширения) |
| Configuration.xml расширения | Свойства, назначение, ChildObjects | [specs/1c-extension-spec.md § 2](specs/1c-extension-spec.md#2-configurationxml--корневой-файл-расширения) |
| Заимствованные / собственные объекты | ObjectBelonging, ExtendedConfigurationObject | [specs/1c-extension-spec.md § 4](specs/1c-extension-spec.md#4-заимствованные-и-собственные-объекты) |
| Расширение свойств (xr:PropertyState) | MultiState, ExtendedProperty | [specs/1c-extension-spec.md § 6](specs/1c-extension-spec.md#6-расширение-свойств-xrpropertystate-и-xrextendedproperty) |
| Модули и декораторы перехвата | &Перед, &После, &Вместо, diff-маркеры | [specs/1c-extension-spec.md § 7](specs/1c-extension-spec.md#7-модули-в-расширениях) |
| Предопределённые элементы | ExtensionState: Native | [specs/1c-extension-spec.md § 8](specs/1c-extension-spec.md#8-предопределённые-элементы-в-расширениях) |

---

## 5. Внешние обработки и отчёты

| Формат | Описание | Спецификация |
|--------|----------|--------------|
| EPF (внешняя обработка) | ExternalDataProcessor | [specs/1c-epf-spec.md § 1](specs/1c-epf-spec.md#1-структура-каталогов) |
| ERF (внешний отчёт) | ExternalReport | [specs/1c-erf-spec.md § 1](specs/1c-erf-spec.md#1-структура-каталогов) |

---

## 6. Общие элементы формата

Общие для всех типов объектов структуры XML описаны в спецификации объектов:

| Тема | Спецификация |
|------|--------------|
| Корневой элемент MetaDataObject | [specs/1c-config-objects-spec.md § 2](specs/1c-config-objects-spec.md#2-общий-формат-xml) |
| Пространства имён XML | [specs/1c-config-objects-spec.md § 2.2](specs/1c-config-objects-spec.md#22-пространства-имён) |
| InternalInfo / GeneratedType | [specs/1c-config-objects-spec.md § 3](specs/1c-config-objects-spec.md#3-internalinfo--внутренняя-информация) |
| Общие свойства Properties | [specs/1c-config-objects-spec.md § 4](specs/1c-config-objects-spec.md#4-общие-элементы-properties) |
| Стандартные реквизиты | [specs/1c-config-objects-spec.md § 5](specs/1c-config-objects-spec.md#5-стандартные-реквизиты-standardattributes) |
| Дочерние объекты (Attribute, TabularSection, Form, Template, Command) | [specs/1c-config-objects-spec.md § 6](specs/1c-config-objects-spec.md#6-дочерние-объекты-childobjects) |
| Формат ссылок на объекты | [specs/1c-config-objects-spec.md § 28](specs/1c-config-objects-spec.md#28-формат-ссылок-на-объекты-метаданных) |
| Различия версий 2.17 → 2.20 | [specs/1c-config-objects-spec.md § 26](specs/1c-config-objects-spec.md#26-различия-версий-платформы) |

---

## 7. DSL-спецификации (компактный формат ввода)

JSON-DSL компилируется скиллами потребителя (`meta-*`, `form-*`, `skd-*`,
`mxl-*`, `role-*` в `.cursor/skills/`). Спеки формата — в kit:

| DSL | Спецификация |
| --- | --- |
| Meta | [specs/meta-dsl-spec.md](specs/meta-dsl-spec.md) |
| Form | [specs/form-dsl-spec.md](specs/form-dsl-spec.md) |
| SKD | [specs/skd-dsl-spec.md](specs/skd-dsl-spec.md) |
| MXL | [specs/mxl-dsl-spec.md](specs/mxl-dsl-spec.md) |
| Role | [specs/role-dsl-spec.md](specs/role-dsl-spec.md) |
| Web (Apache / vrd) | [specs/web-spec.md](specs/web-spec.md) |
| Пакетный 1cv8 | [specs/build-spec.md](specs/build-spec.md) |
| EPF/ERF autotest | [specs/epf-erf-autotest-scenario-spec.md](specs/epf-erf-autotest-scenario-spec.md) |
