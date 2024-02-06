// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

use crate::configure::parameters::Input;
use crate::dscerror::DscError;
use crate::dscresources::dscresource::Invoke;
use crate::DscResource;
use crate::discovery::Discovery;
use crate::parser::Statement;
use self::context::Context;
use self::config_doc::{Configuration, DataType};
use self::depends_on::get_resource_invocation_order;
use self::config_result::{ConfigurationGetResult, ConfigurationSetResult, ConfigurationTestResult, ConfigurationExportResult};
use self::contraints::{check_length, check_number_limits, check_allowed_values};
use serde_json::{Map, Value};
use std::collections::{HashMap, HashSet};
use tracing::debug;

pub mod context;
pub mod config_doc;
pub mod config_result;
pub mod contraints;
pub mod depends_on;
pub mod parameters;

pub struct Configurator {
    config: String,
    context: Context,
    discovery: Discovery,
    statement_parser: Statement,
}

#[derive(Debug, Clone, Copy)]
pub enum ErrorAction {
    Continue,
    Stop,
}

/// Add the results of an export operation to a configuration.
///
/// # Arguments
///
/// * `resource` - The resource to export.
/// * `conf` - The configuration to add the results to.
///
/// # Panics
///
/// Doesn't panic because there is a match/Some check before unwrap(); false positive.
///
/// # Errors
///
/// This function will return an error if the underlying resource fails.
pub fn add_resource_export_results_to_configuration(resource: &DscResource, provider_resource: Option<&DscResource>, conf: &mut Configuration, input: &str) -> Result<(), DscError> {
   
    let export_result = match provider_resource {
        Some(_) => provider_resource.unwrap().export(input)?,
        _ => resource.export(input)?
    };

    for (i, instance) in export_result.actual_state.iter().enumerate() {
        let mut r = config_doc::Resource::new();
        r.resource_type = resource.type_name.clone();
        r.name = format!("{}-{i}", r.resource_type);
        let props: Map<String, Value> = serde_json::from_value(instance.clone())?;
        r.properties = escape_property_values(&props)?;

        conf.resources.push(r);
    }

    Ok(())
}

// for values returned by resources, they may look like expressions, so we make sure to escape them in case
// they are re-used to apply configuration
fn escape_property_values(properties: &Map<String, Value>) -> Result<Option<Map<String, Value>>, DscError> {
    let mut result: Map<String, Value> = Map::new();
    for (name, value) in properties {
        match value {
            Value::Object(object) => {
                let value = escape_property_values(&object.clone())?;
                result.insert(name.clone(), serde_json::to_value(value)?);
                continue;
            },
            Value::Array(array) => {
                let mut result_array: Vec<Value> = Vec::new();
                for element in array {
                    match element {
                        Value::Object(object) => {
                            let value = escape_property_values(&object.clone())?;
                            result_array.push(serde_json::to_value(value)?);
                            continue;
                        },
                        Value::Array(_) => {
                            return Err(DscError::Parser("Nested arrays not supported".to_string()));
                        },
                        Value::String(_) => {
                            // use as_str() so that the enclosing quotes are not included for strings
                            let Some(statement) = element.as_str() else {
                                return Err(DscError::Parser("Array element could not be transformed as string".to_string()));
                            };
                            if statement.starts_with('[') && statement.ends_with(']') {
                                result_array.push(Value::String(format!("[{statement}")));
                            } else {
                                result_array.push(element.clone());
                            }
                        }
                        _ => {
                            result_array.push(element.clone());
                        }
                    }
                }
                result.insert(name.clone(), serde_json::to_value(result_array)?);
            },
            Value::String(_) => {
                // use as_str() so that the enclosing quotes are not included for strings
                let Some(statement) = value.as_str() else {
                    return Err(DscError::Parser(format!("Property value '{value}' could not be transformed as string")));
                };
                if statement.starts_with('[') && statement.ends_with(']') {
                    result.insert(name.clone(), Value::String(format!("[{statement}")));
                } else {
                    result.insert(name.clone(), value.clone());
                }
            },
            _ => {
                result.insert(name.clone(), value.clone());
            },
        }
    }
    Ok(Some(result))
}

impl Configurator {
    /// Create a new `Configurator` instance.
    ///
    /// # Arguments
    ///
    /// * `config` - The configuration to use in JSON.
    ///
    /// # Errors
    ///
    /// This function will return an error if the configuration is invalid or the underlying discovery fails.
    pub fn new(config: &str) -> Result<Configurator, DscError> {
        let discovery = Discovery::new()?;
        Ok(Configurator {
            config: config.to_owned(),
            context: Context::new(),
            discovery,
            statement_parser: Statement::new()?,
        })
    }

    /// Invoke the get operation on a resource.
    ///
    /// # Arguments
    ///
    /// * `error_action` - The error action to use.
    /// * `progress_callback` - A callback to call when progress is made.
    ///
    /// # Errors
    ///
    /// This function will return an error if the underlying resource fails.
    pub fn invoke_get(&mut self, _error_action: ErrorAction, _progress_callback: impl Fn() + 'static) -> Result<ConfigurationGetResult, DscError> {
        let config = self.validate_config()?;
        let mut result = ConfigurationGetResult::new();
        for resource in get_resource_invocation_order(&config, &mut self.statement_parser, &self.context)? {
            let properties = self.invoke_property_expressions(&resource.properties)?;
            let Some(dsc_resource) = self.discovery.find_resource(&resource.resource_type.to_lowercase()) else {
                return Err(DscError::ResourceNotFound(resource.resource_type));
            };
            debug!("resource_type {}", &resource.resource_type);
            let filter = serde_json::to_string(&properties)?;
            let get_result = dsc_resource.get(&filter)?;
            let resource_result = config_result::ResourceGetResult {
                name: resource.name.clone(),
                resource_type: resource.resource_type.clone(),
                result: get_result,
            };
            result.results.push(resource_result);
        }

        Ok(result)
    }

    /// Invoke the set operation on a resource.
    ///
    /// # Arguments
    ///
    /// * `error_action` - The error action to use.
    /// * `progress_callback` - A callback to call when progress is made.
    ///
    /// # Errors
    ///
    /// This function will return an error if the underlying resource fails.
    pub fn invoke_set(&mut self, skip_test: bool, _error_action: ErrorAction, _progress_callback: impl Fn() + 'static) -> Result<ConfigurationSetResult, DscError> {
        let config = self.validate_config()?;
        let mut result = ConfigurationSetResult::new();
        for resource in get_resource_invocation_order(&config, &mut self.statement_parser, &self.context)? {
            let properties = self.invoke_property_expressions(&resource.properties)?;
            let Some(dsc_resource) = self.discovery.find_resource(&resource.resource_type.to_lowercase()) else {
                return Err(DscError::ResourceNotFound(resource.resource_type));
            };
            debug!("resource_type {}", &resource.resource_type);
            let desired = serde_json::to_string(&properties)?;
            let set_result = dsc_resource.set(&desired, skip_test)?;
            let resource_result = config_result::ResourceSetResult {
                name: resource.name.clone(),
                resource_type: resource.resource_type.clone(),
                result: set_result,
            };
            result.results.push(resource_result);
        }

        Ok(result)
    }

    /// Invoke the test operation on a resource.
    ///
    /// # Arguments
    ///
    /// * `error_action` - The error action to use.
    /// * `progress_callback` - A callback to call when progress is made.
    ///
    /// # Errors
    ///
    /// This function will return an error if the underlying resource fails.
    pub fn invoke_test(&mut self, _error_action: ErrorAction, _progress_callback: impl Fn() + 'static) -> Result<ConfigurationTestResult, DscError> {
        let config = self.validate_config()?;
        let mut result = ConfigurationTestResult::new();
        for resource in get_resource_invocation_order(&config, &mut self.statement_parser, &self.context)? {
            let properties = self.invoke_property_expressions(&resource.properties)?;
            let Some(dsc_resource) = self.discovery.find_resource(&resource.resource_type.to_lowercase()) else {
                return Err(DscError::ResourceNotFound(resource.resource_type));
            };
            debug!("resource_type {}", &resource.resource_type);
            let expected = serde_json::to_string(&properties)?;
            let test_result = dsc_resource.test(&expected)?;
            let resource_result = config_result::ResourceTestResult {
                name: resource.name.clone(),
                resource_type: resource.resource_type.clone(),
                result: test_result,
            };
            result.results.push(resource_result);
        }

        Ok(result)
    }

    /// Invoke the export operation on a configuration.
    ///
    /// # Arguments
    ///
    /// * `error_action` - The error action to use.
    /// * `progress_callback` - A callback to call when progress is made.
    ///
    /// # Returns
    ///
    /// * `ConfigurationExportResult` - The result of the export operation.
    ///
    /// # Errors
    ///
    /// This function will return an error if the underlying resource fails.
    pub fn invoke_export(&mut self, _error_action: ErrorAction, _progress_callback: impl Fn() + 'static) -> Result<ConfigurationExportResult, DscError> {
        let config = self.validate_config()?;

        let duplicates = Self::find_duplicate_resource_types(&config);
        if !duplicates.is_empty()
        {
            let duplicates_string = &duplicates.join(",");
            return Err(DscError::Validation(format!("Resource(s) {duplicates_string} specified multiple times")));
        }

        let mut result = ConfigurationExportResult::new();
        let mut conf = config_doc::Configuration::new();

        for resource in &config.resources {
            let Some(dsc_resource) = self.discovery.find_resource(&resource.resource_type.to_lowercase()) else {
                return Err(DscError::ResourceNotFound(resource.resource_type.clone()));
            };

            let input = serde_json::to_string(&resource.properties)?;
            add_resource_export_results_to_configuration(dsc_resource, Some(dsc_resource), &mut conf, input.as_str())?;
        }

        result.result = Some(conf);

        Ok(result)
    }

    /// Set the parameters context for the configuration.
    ///
    /// # Arguments
    ///
    /// * `parameters_input` - The parameters to set.
    ///
    /// # Errors
    ///
    /// This function will return an error if the parameters are invalid.
    pub fn set_parameters(&mut self, parameters_input: &Option<Value>) -> Result<(), DscError> {
        // set default parameters first
        let config = serde_json::from_str::<Configuration>(self.config.as_str())?;
        let Some(parameters) = &config.parameters else {
            if parameters_input.is_none() {
                return Ok(());
            }
            return Err(DscError::Validation("No parameters defined in configuration".to_string()));
        };

        for (name, parameter) in parameters {
            if let Some(default_value) = &parameter.default_value {
                // TODO: default values can be expressions
                // TODO: validate default value matches the type
                self.context.parameters.insert(name.clone(), default_value.clone());
            }
        }

        let Some(parameters_input) = parameters_input else {
            return Ok(());
        };

        let parameters: HashMap<String, Value> = serde_json::from_value::<Input>(parameters_input.clone())?.parameters;
        let Some(parameters_constraints) = &config.parameters else {
            return Err(DscError::Validation("No parameters defined in configuration".to_string()));
        };
        for (name, value) in parameters {
            if let Some(constraint) = parameters_constraints.get(&name) {
                check_length(&name, &value, constraint)?;
                check_allowed_values(&name, &value, constraint)?;
                check_number_limits(&name, &value, constraint)?;
                // TODO: additional array constraints
                // TODO: object constraints

                match constraint.parameter_type {
                    DataType::String | DataType::SecureString => {
                        if !value.is_string() {
                            return Err(DscError::Validation(format!("Parameter '{name}' is not a string")));
                        }
                    },
                    DataType::Int => {
                        if !value.is_i64() {
                            return Err(DscError::Validation(format!("Parameter '{name}' is not an integer")));
                        }
                    },
                    DataType::Bool => {
                        if !value.is_boolean() {
                            return Err(DscError::Validation(format!("Parameter '{name}' is not a boolean")));
                        }
                    },
                    DataType::Array => {
                        if !value.is_array() {
                            return Err(DscError::Validation(format!("Parameter '{name}' is not an array")));
                        }
                    },
                    DataType::Object | DataType::SecureObject => {
                        if !value.is_object() {
                            return Err(DscError::Validation(format!("Parameter '{name}' is not an object")));
                        }
                    },
                }

                self.context.parameters.insert(name.clone(), value.clone());
            }
            else {
                return Err(DscError::Validation(format!("Parameter '{name}' not defined in configuration")));
            }
        }
        Ok(())
    }

    fn find_duplicate_resource_types(config: &Configuration) -> Vec<String>
    {
        let mut map: HashMap<&String, i32> = HashMap::new();
        let mut result: HashSet<String> = HashSet::new();
        let resource_list = &config.resources;
        if resource_list.is_empty() {
            return Vec::new();
        }

        for r in resource_list
        {
            let v = map.entry(&r.resource_type).or_insert(0);
            *v += 1;
            if *v > 1 {
                result.insert(r.resource_type.clone());
            }
        }

        result.into_iter().collect()
    }

    fn validate_config(&mut self) -> Result<Configuration, DscError> {
        let config: Configuration = serde_json::from_str(self.config.as_str())?;

        // Perform discovery of resources used in config
        let mut required_resources = config.resources.iter().map(|p| p.resource_type.to_lowercase()).collect::<Vec<String>>();
        required_resources.sort_unstable();
        required_resources.dedup();
        self.discovery.discover_resources(&required_resources);
        Ok(config)
    }

    fn invoke_property_expressions(&mut self, properties: &Option<Map<String, Value>>) -> Result<Option<Map<String, Value>>, DscError> {
        if properties.is_none() {
            return Ok(None);
        }

        let mut result: Map<String, Value> = Map::new();
        if let Some(properties) = properties {
            for (name, value) in properties {
                match value {
                    Value::Object(object) => {
                        let value = self.invoke_property_expressions(&Some(object.clone()))?;
                        result.insert(name.clone(), serde_json::to_value(value)?);
                        continue;
                    },
                    Value::Array(array) => {
                        let mut result_array: Vec<Value> = Vec::new();
                        for element in array {
                            match element {
                                Value::Object(object) => {
                                    let value = self.invoke_property_expressions(&Some(object.clone()))?;
                                    result_array.push(serde_json::to_value(value)?);
                                    continue;
                                },
                                Value::Array(_) => {
                                    return Err(DscError::Parser("Nested arrays not supported".to_string()));
                                },
                                Value::String(_) => {
                                    // use as_str() so that the enclosing quotes are not included for strings
                                    let Some(statement) = element.as_str() else {
                                        return Err(DscError::Parser("Array element could not be transformed as string".to_string()));
                                    };
                                    let statement_result = self.statement_parser.parse_and_execute(statement, &self.context)?;
                                    result_array.push(Value::String(statement_result));
                                }
                                _ => {
                                    result_array.push(element.clone());
                                }
                            }
                        }
                        result.insert(name.clone(), serde_json::to_value(result_array)?);
                    },
                    Value::String(_) => {
                        // use as_str() so that the enclosing quotes are not included for strings
                        let Some(statement) = value.as_str() else {
                            return Err(DscError::Parser(format!("Property value '{value}' could not be transformed as string")));
                        };
                        let statement_result = self.statement_parser.parse_and_execute(statement, &self.context)?;
                        result.insert(name.clone(), Value::String(statement_result));
                    },
                    _ => {
                        result.insert(name.clone(), value.clone());
                    },
                }
            }
        }
        Ok(Some(result))
    }
}
